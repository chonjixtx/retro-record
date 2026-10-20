import AVFoundation
import Dispatch
import Photos
import ReplayKit

/// 全屏录制内核。
///
/// 关键设计：
/// 1. ReplayKit 的 Broadcast Upload Extension 跑在独立进程里，主 App 被切到后台或杀掉，录制依然继续。
/// 2. 不做内存环形缓冲（扩展进程有内存上限，堆 10 分钟原始帧必崩），改为每 10 秒落盘一个 mp4 分片。
/// 3. 每落一片就剪掉超出保留窗口的旧片 —— 这就是"600 秒后自动删除继续录"。
/// 4. 所有状态经 App Group 共享给主 App，主 App 只负责取片、拼接、导出。
@objc(SampleHandler)
final class SampleHandler: RPBroadcastSampleHandler {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var config: RecorderConfig = .default
    private var segmentStart: CMTime?
    private var lastVideoTime: CMTime?
    private var didStartSession = false

    /// 保护 pendingSaveSeconds，供 Darwin 通知回调与录制线程之间传递
    private let stateLock = NSLock()
    private var pendingSaveSeconds: Double?
    /// 降级模式下扩展读不到主 App 的配置文件，保留秒数只能靠 Darwin 通道同步
    private var retentionSeconds: Double = 600
    /// 停止录制时用来等最后一个分片收尾落盘
    private var stopSignal: DispatchSemaphore?

    /// 保存请求监听句柄。broadcastFinished 必须注销，
    /// 否则扩展进程被复用时会回调到已释放的 self（野指针崩溃）
    private var saveObservation: NotifyBridge.Observation?
    private var configObservation: NotifyBridge.Observation?
    private var pingObservation: NotifyBridge.Observation?
    private var triggerObservation: NotifyBridge.Observation?

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 共享容器拿不到也继续录：此时走降级流程，
        // 分片写在本扩展沙盒里，用户点保存时由本进程自行拼接并直接存进相册。
        config = RecorderConfigStore.load().clamped
        retentionSeconds = config.retentionSeconds
        _ = AppGroup.segmentsURL
        SegmentStore.prune(retentionSeconds: currentRetention())
        Heartbeat.setActive(true)
        Heartbeat.beat()

        LogBridge.start()
        // 从这一行开始，日志同时落盘到共享目录：主 App 在用户打游戏时多半是挂起的，
        // 收不到 Darwin 通知，事后只能靠文件还原扩展这边发生了什么
        NotifyBridge.mirrorToFile = true
        NotifyBridge.postLog("EXT_START_\(AppGroup.isShared ? "shared" : "degraded")")
        NotifyBridge.postLog("DIR_\(AppGroup.containerURL?.lastPathComponent ?? "nil")")
        NotifyBridge.postLog("AUTH_\(Self.photoAuthTag())")
        NotifyBridge.postLog("SEGS_\(Self.segmentCount())")
        registerSaveObserver()
        registerConfigObserver()
        registerPingObserver()
        registerTriggerObserver()
    }

    override func broadcastPaused() {
        Heartbeat.beat()
    }

    override func broadcastResumed() {
        rotateSegment(force: true)
    }

    override func broadcastFinished() {
        // 先把最后一个分片收尾，并最多等 3 秒让它真正写完
        let signal = DispatchSemaphore(value: 0)
        stopSignal = signal
        rotateSegment(force: true)
        _ = signal.wait(timeout: .now() + 3)
        stopSignal = nil

        Heartbeat.setActive(false)
        if let observation = saveObservation {
            NotifyBridge.unobserve(observation)
            saveObservation = nil
        }
        if let observation = configObservation {
            NotifyBridge.unobserve(observation)
            configObservation = nil
        }
        if let observation = pingObservation {
            NotifyBridge.unobserve(observation)
            pingObservation = nil
        }
        if let observation = triggerObservation {
            NotifyBridge.unobserve(observation)
            triggerObservation = nil
        }

        // 降级模式下的保底路径：用户停录制就等于保存。
        // 这条路径完全在本进程内完成，不依赖任何跨进程通信。
        if !AppGroup.isShared {
            autoSaveOnStop()
        }

        NotifyBridge.postLog("EXT_STOP")
        NotifyBridge.mirrorToFile = false
        LogBridge.stop()
    }

    // MARK: - 帧处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            handleVideo(sampleBuffer)
        case .audioApp:
            handleAudio(sampleBuffer, isMicrophone: false)
        case .audioMic:
            if config.microphoneEnabled {
                handleAudio(sampleBuffer, isMicrophone: true)
            }
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        // 保存请求在这里落地：先收尾当前分片，再异步导出
        if let seconds = drainPendingSave() {
            rotateSegment(force: true)
            let target = max(seconds, 5)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.exportRecent(seconds: target)
            }
        }

        if writer == nil {
            guard startNewSegment(with: sampleBuffer) else { return }
        }
        guard let input = videoInput else { return }

        if !didStartSession {
            writer?.startSession(atSourceTime: pts)
            segmentStart = pts
            didStartSession = true
        }
        lastVideoTime = pts

        if input.isReadyForMoreMediaData {
            if let adaptor = pixelAdaptor,
               let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                adaptor.append(imageBuffer, withPresentationTime: pts)
            } else {
                // 极少数设备直接给压缩帧，回退为直接追加
                input.append(sampleBuffer)
            }
        }

        if let start = segmentStart, (pts - start).seconds >= SegmentStore.segmentSeconds {
            rotateSegment(force: false)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        guard didStartSession, let currentWriter = writer else { return }

        if isMicrophone {
            if micInput == nil {
                micInput = makeAudioInput(for: sampleBuffer, writer: currentWriter)
            }
            if let input = micInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else {
            if appAudioInput == nil {
                appAudioInput = makeAudioInput(for: sampleBuffer, writer: currentWriter)
            }
            if let input = appAudioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    // MARK: - 分片

    /// 失败日志节流：startNewSegment 是每帧都可能调用的，不能每帧都广播
    private var lastFailLogAt: TimeInterval = 0

    private func segmentFail(_ reason: String) -> Bool {
        let now = Date().timeIntervalSince1970
        if now - lastFailLogAt > 5 {
            lastFailLogAt = now
            NotifyBridge.postLog("SEG_NEW_FAIL_\(reason)")
        }
        return false
    }

    private func startNewSegment(with sampleBuffer: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return segmentFail("noformat")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 0, height > 0 else { return segmentFail("badwh") }
        guard let output = SegmentStore.nextURL() else { return segmentFail("nourl") }
        try? FileManager.default.removeItem(at: output)
        guard let newWriter = try? AVAssetWriter(url: output, fileType: .mp4) else {
            return segmentFail("nowriter")
        }

        newWriter.shouldOptimizeForNetworkUse = false
        // 必须关闭分片写入，否则产出的 mp4 没有 moov，主 App 无法直接拼接
        newWriter.movieFragmentInterval = .invalid

        let bitrate = Int(config.bitrateMbps * 1_000_000)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: 30
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        input.transform = preferredTransform(for: sampleBuffer)

        let pixelFormat = CMSampleBufferGetImageBuffer(sampleBuffer).map { CVPixelBufferGetPixelFormatType($0) }
            ?? kCVPixelFormatType_32BGRA
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard newWriter.canAdd(input) else { return segmentFail("cannotadd") }
        newWriter.add(input)
        guard newWriter.startWriting() else {
            return segmentFail("startwrite_\(newWriter.status.rawValue)")
        }
        NotifyBridge.postLog("SEG_NEW_\(width)x\(height)")

        writer = newWriter
        videoInput = input
        pixelAdaptor = adaptor
        return true
    }

    private func rotateSegment(force: Bool) {
        guard let finishingWriter = writer else {
            resetSegmentState()
            stopSignal?.signal()
            return
        }

        let finishingVideo = videoInput
        let finishingAppAudio = appAudioInput
        let finishingMic = micInput
        let endTime = lastVideoTime
        resetSegmentState()

        if let endTime, endTime.isValid {
            finishingWriter.endSession(atSourceTime: endTime)
        }
        finishingVideo?.markAsFinished()
        finishingAppAudio?.markAsFinished()
        finishingMic?.markAsFinished()

        guard finishingWriter.status == .writing else {
            NotifyBridge.postLog("SEG_BAD_status_\(finishingWriter.status.rawValue)")
            stopSignal?.signal()
            return
        }
        finishingWriter.finishWriting { [weak self] in
            guard let self else { return }
            SegmentStore.prune(retentionSeconds: self.currentRetention())
            Heartbeat.beat()
            // 降级模式下主 App 读不到分片目录，这条日志是它判断"到底在不在录"的唯一依据
            NotifyBridge.postLog("SEG_OK_\(Self.segmentCount())")
            self.stopSignal?.signal()
        }
        if !force { Heartbeat.beat() }
    }

    // MARK: - 保留时长

    private func currentRetention() -> Double {
        stateLock.lock()
        let value = retentionSeconds
        stateLock.unlock()
        return value
    }

    private func setRetention(_ value: Double) {
        stateLock.lock()
        retentionSeconds = value
        stateLock.unlock()
    }

    private func registerConfigObserver() {
        configObservation = NotifyBridge.observeConfig { [weak self] seconds in
            guard let self else { return }
            let previous = self.currentRetention()
            self.setRetention(seconds)
            // 主 App 会周期性补发同一条配置，值没变就别刷日志
            guard abs(previous - seconds) > 0.5 else { return }
            SegmentStore.prune(retentionSeconds: seconds)
            NotifyBridge.postLog("CFG_\(Int(seconds))")
        }
    }

    /// 回答主 App 的探活，顺带把当前状态一起报回去
    private func registerPingObserver() {
        pingObservation = NotifyBridge.observePing { [weak self] in
            guard let self else { return }
            NotifyBridge.postLog("PONG_\(AppGroup.isShared ? "shared" : "degraded")")
            NotifyBridge.postLog("SEGS_\(Self.segmentCount())")
            NotifyBridge.postLog("AUTH_\(Self.photoAuthTag())")
            NotifyBridge.postLog("RET_\(Int(self.currentRetention()))")
        }
    }

    private func resetSegmentState() {
        writer = nil
        videoInput = nil
        appAudioInput = nil
        micInput = nil
        pixelAdaptor = nil
        segmentStart = nil
        lastVideoTime = nil
        didStartSession = false
    }

    // MARK: - 辅助

    private func makeAudioInput(for sampleBuffer: CMSampleBuffer, writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: Int(asbd.pointee.mChannelsPerFrame),
            AVSampleRateKey: asbd.pointee.mSampleRate,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    /// ReplayKit 给的是物理像素方向，写进 mp4 时必须转成 transform，否则导出的视频是躺着的
    private func preferredTransform(for sampleBuffer: CMSampleBuffer) -> CGAffineTransform {
        guard let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
        else { return .identity }

        switch orientation {
        case .up: return .identity
        case .down: return CGAffineTransform(rotationAngle: .pi)
        case .left: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .right: return CGAffineTransform(rotationAngle: .pi / 2)
        case .upMirrored: return CGAffineTransform(scaleX: -1, y: 1)
        case .downMirrored: return CGAffineTransform(rotationAngle: .pi).scaledBy(x: -1, y: 1)
        case .leftMirrored: return CGAffineTransform(rotationAngle: -.pi / 2).scaledBy(x: -1, y: 1)
        case .rightMirrored: return CGAffineTransform(rotationAngle: .pi / 2).scaledBy(x: -1, y: 1)
        @unknown default: return .identity
        }
    }

    // MARK: - 降级模式：主 App 无法读分片时，由本进程自行导出到相册

    private func registerSaveObserver() {
        saveObservation = NotifyBridge.observeSave { [weak self] seconds in
            self?.handleSaveRequest(seconds: seconds)
        }
    }

    /// 外部进程（越狱 tweak 的游戏内悬浮按钮等）请求保存。
    ///
    /// 与主 App 的保存请求不同，这里**不受 AppGroup.isShared 限制**：
    /// 触发方无法保证主 App 没被系统挂起，而 Darwin 通知唤不醒挂起进程，
    /// 主 App 一旦挂起就收不到任何指令；本扩展在录制期间必定存活，
    /// 所以这里一律由本进程收尾分片并导出到相册。
    private func registerTriggerObserver() {
        triggerObservation = NotifyBridge.observeTrigger { [weak self] seconds in
            guard let self else { return }
            let target = max(seconds, 5)
            NotifyBridge.postLog("TRIG_SAVE_\(Int(target))")
            self.stateLock.lock()
            self.pendingSaveSeconds = target
            self.stateLock.unlock()
        }
    }

    private func handleSaveRequest(seconds: Double) {
        // 只有降级模式才由扩展导出；共享模式交给主 App 处理
        if AppGroup.isShared {
            NotifyBridge.postLog("SAVE_IGN_shared")
            return
        }
        NotifyBridge.postLog("SAVE_REQ_\(Int(seconds))")
        NotifyBridge.postLog("AUTH_\(Self.photoAuthTag())")

        // Darwin 回调不一定在录制线程上，这里只置标志，
        // 真正的分片收尾交给录制线程执行，避免并发操作 AVAssetWriter。
        stateLock.lock()
        pendingSaveSeconds = seconds
        stateLock.unlock()
    }

    /// 由录制线程调用：处理挂起的保存请求
    private func drainPendingSave() -> Double? {
        stateLock.lock()
        let value = pendingSaveSeconds
        pendingSaveSeconds = nil
        stateLock.unlock()
        return value
    }

    // MARK: - 日志辅助

    private static func photoAuthTag() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func segmentCount() -> Int {
        guard let dir = AppGroup.segmentsURL else { return -1 }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "mp4" }.count
    }

    // MARK: - 导出

    private func listSegments() -> [URL] {
        guard let dir = AppGroup.segmentsURL else {
            NotifyBridge.postLog("SAVE_FAIL_nodir")
            return []
        }
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            NotifyBridge.postLog("SAVE_FAIL_listdir")
            return []
        }
        return all
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }
    }

    /// 从最新往回凑够需要的秒数
    private func pickSegments(from files: [URL], seconds: Double) -> [URL] {
        var picked: [URL] = []
        var total: Double = 0
        for url in files.reversed() {
            let duration = AVURLAsset(url: url).duration.seconds
            guard duration.isFinite, duration > 0.02 else { continue }
            picked.insert(url, at: 0)
            total += duration
            if total >= seconds { break }
        }
        return picked
    }

    private func exportRecent(seconds: Double) {
        let files = listSegments()
        NotifyBridge.postLog("SEGS_\(files.count)")
        let picked = pickSegments(from: files, seconds: seconds)
        NotifyBridge.postLog("PICK_\(picked.count)_of_\(files.count)")
        guard !picked.isEmpty else {
            NotifyBridge.postLog("SAVE_FAIL_nopick")
            return
        }
        export(picked: picked, completion: nil)
    }

    private func export(picked: [URL], completion: ((Bool) -> Void)?) {
        guard !picked.isEmpty else {
            completion?(false)
            return
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            NotifyBridge.postLog("SAVE_FAIL_notrack")
            saveSegmentsDirectly(picked, completion: completion)
            return
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var transform: CGAffineTransform?
        for url in picked {
            let asset = AVURLAsset(url: url)
            guard let source = asset.tracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try? videoTrack.insertTimeRange(range, of: source, at: cursor)
            if transform == nil { transform = source.preferredTransform }
            if let audioTrack, let audioSource = asset.tracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: audioSource, at: cursor)
            }
            cursor = cursor + range.duration
        }
        videoTrack.preferredTransform = transform ?? .identity

        // 直通模式不重编码：扩展进程内存受限，重编码 600 秒 1080p 会被系统回收
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            NotifyBridge.postLog("SAVE_FAIL_noexporter")
            saveSegmentsDirectly(picked, completion: completion)
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retro-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        NotifyBridge.postLog("EXPORT_BEGIN")

        exporter.exportAsynchronously { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard exporter.status == .completed else {
                let tag = exporter.error?.localizedDescription ?? "nil"
                NotifyBridge.postLog("EXPORT_FAIL_\(exporter.status.rawValue)")
                NotifyBridge.postLog("EXPORT_ERR_\(tag)")
                try? FileManager.default.removeItem(at: outputURL)
                // 合成导出失败就直接落单个分片，保证至少有东西进相册
                self.saveSegmentsDirectly(picked, completion: completion)
                return
            }
            NotifyBridge.postLog("EXPORT_OK")
            self.saveToPhotos(
                url: outputURL,
                cleanup: { try? FileManager.default.removeItem(at: outputURL) },
                done: { ok in completion?(ok) }
            )
        }
    }

    private func saveToPhotos(url: URL, cleanup: @escaping () -> Void, done: @escaping (Bool) -> Void) {
        requestPhotoAuthIfNeeded { [weak self] granted in
            guard let self else { cleanup(); done(false); return }
            guard granted else {
                // 扩展进程拿不到相册权限（iOS 上扩展里弹不出授权框是最常见原因）。
                // 这时不能把 mp4 当临时文件删掉 —— 先留一份，用户至少还有东西可拿。
                NotifyBridge.postLog("PHOTO_AUTH_NO")
                self.keepCopy(of: url)
                cleanup()
                done(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    NotifyBridge.postLog("PHOTO_OK")
                } else {
                    let ns = error as NSError?
                    NotifyBridge.postLog("PHOTO_FAIL_\(ns?.code ?? -1)")
                    self.keepCopy(of: url)
                }
                cleanup()
                done(success)
            }
        }
    }

    /// 相册权限：已授权直接放行；未决定时主动申请一次（带 3 秒超时，
    /// 因为扩展进程里授权回调有可能永远不来，不能干等）。
    private func requestPhotoAuthIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        NotifyBridge.postLog("AUTH_NOW_\(Self.photoAuthTag())")
        if status == .authorized || status == .limited {
            completion(true)
            return
        }
        if status != .notDetermined {
            completion(false)
            return
        }
        let gate = NSLock()
        var settled = false
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            gate.lock()
            if settled { gate.unlock(); return }
            settled = true
            gate.unlock()
            NotifyBridge.postLog("AUTH_REQ_\(st == .authorized || st == .limited ? "ok" : "no")")
            completion(st == .authorized || st == .limited)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            gate.lock()
            if settled { gate.unlock(); return }
            settled = true
            gate.unlock()
            NotifyBridge.postLog("AUTH_REQ_TIMEOUT")
            completion(PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized)
        }
    }

    /// 导出失败 / 相册写不进去时，把成品 mp4 留一份在导出目录里。
    private func keepCopy(of url: URL) {
        guard let dir = AppGroup.exportsURL else {
            NotifyBridge.postLog("KEEP_NODIR")
            return
        }
        let name = "retro-\(Int(Date().timeIntervalSince1970)).mp4"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            NotifyBridge.postLog("KEEP_OK_\(name)")
        } catch {
            NotifyBridge.postLog("KEEP_FAIL")
        }
    }

    /// 兜底：把选中的分片逐个塞进相册。每个分片本身就是一个可播放的 mp4，
    /// 不经过 AVAssetExportSession，成功率最高，代价是相册里会有多段。
    private func saveSegmentsDirectly(_ urls: [URL], completion: ((Bool) -> Void)? = nil) {
        let capped = Array(urls.suffix(20))
        NotifyBridge.postLog("PARTS_BEGIN_\(capped.count)")
        saveOneSegment(capped, index: 0, done: 0) { saved in
            NotifyBridge.postLog("PARTS_OK_\(saved)_of_\(capped.count)")
            completion?(saved > 0)
        }
    }

    private func saveOneSegment(_ urls: [URL], index: Int, done: Int, finish: @escaping (Int) -> Void) {
        guard index < urls.count else {
            finish(done)
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: urls[index])
        } completionHandler: { [weak self] success, error in
            guard let self else { return }
            if !success {
                let code = (error as NSError?)?.code ?? -1
                NotifyBridge.postLog("PART_FAIL_\(index)_\(code)")
                // 单个分片本身就是可播放的 mp4，相册写不进去就留一份文件
                self.keepCopy(of: urls[index])
            }
            self.saveOneSegment(urls, index: index + 1, done: done + (success ? 1 : 0), finish: finish)
        }
    }

    // MARK: - 停止录制即保存（不依赖任何跨进程通信的保底路径）

    private func autoSaveOnStop() {
        let files = listSegments()
        let picked = pickSegments(from: files, seconds: currentRetention())
        NotifyBridge.postLog("STOP_SAVE_\(picked.count)_of_\(files.count)")
        guard !picked.isEmpty else { return }

        let sem = DispatchSemaphore(value: 0)
        export(picked: picked) { ok in
            NotifyBridge.postLog(ok ? "STOP_OK" : "STOP_FAIL")
            sem.signal()
        }
        // 系统给 broadcastFinished 的时间有限，最多等 8 秒，等不到就算了
        _ = sem.wait(timeout: .now() + 8)
    }
}
