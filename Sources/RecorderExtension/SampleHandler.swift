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
    /// 上一次收到外部保存指令的时间。游戏内悬浮窗为了防止单条通知丢失会连发三次，
    /// 不去重的话会导出三遍，相册里多出两个几乎一样的视频
    private var lastTriggerAt: Double = 0
    /// 停止录制时用来等最后一个分片收尾落盘
    private var stopSignal: DispatchSemaphore?

    /// 保存请求监听句柄。broadcastFinished 必须注销，
    /// 否则扩展进程被复用时会回调到已释放的 self（野指针崩溃）
    private var saveObservation: NotifyBridge.Observation?
    private var configObservation: NotifyBridge.Observation?
    private var pingObservation: NotifyBridge.Observation?
    private var triggerObservation: NotifyBridge.Observation?
    private var bitrateObservation: NotifyBridge.Observation?
    private var resObservation: NotifyBridge.Observation?

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
        registerBitrateObserver()
        registerResObserver()
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
        if let observation = bitrateObservation {
            NotifyBridge.unobserve(observation)
            bitrateObservation = nil
        }
        if let observation = resObservation {
            NotifyBridge.unobserve(observation)
            resObservation = nil
        }

        // 保底路径：录制一结束就把已有的分片存进相册，不依赖任何跨进程通信。
        //
        // 以前只在降级模式做，结果共享模式下广播一旦被系统杀掉（进大型游戏内存紧张时
        // 很常见），已录的分片就全白录了 —— 用户点保存按钮没反应、相册空空如也，
        // 根因往往就在这里。broadcastFinished 是本进程最后一次能行动的机会，必须兜住。
        autoSaveOnStop()

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
            // 立刻把这一刻的片段列表冻结下来。录制线程还在往前写新片段，
            // 等导出真正开始时再列目录，就会把「按下保存之后」的内容也算进来 ——
            // 用户看到的就是保存之后的录像，而不是按下前那一段。
            let frozen = listSegments()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.exportRecent(seconds: target, files: frozen)
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
        var width = Int(dimensions.width)
        var height = Int(dimensions.height)
        guard width > 0, height > 0 else { return segmentFail("badwh") }

        // 分辨率上限：只向下缩（横屏时高度可能是短边，按长边比较更稳）
        if config.resolutionCapHeight > 0 {
            let longEdge = max(width, height)
            if longEdge > config.resolutionCapHeight {
                let scale = Double(config.resolutionCapHeight) / Double(longEdge)
                width = max((Int(Double(width) * scale) / 2) * 2, 2)
                height = max((Int(Double(height) * scale) / 2) * 2, 2)
            }
        }
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
            // 多留 20 秒：保留窗口按时间戳卡边，正好等于请求时长时落盘必然不够
            self.setRetention(seconds + 20)
            // 主 App 会周期性补发同一条配置，值没变就别刷日志
            guard abs(previous - seconds) > 0.5 else { return }
            SegmentStore.prune(retentionSeconds: seconds + 20)
            NotifyBridge.postLog("CFG_\(Int(seconds))")
        }
    }

    /// 回答主 App 的探活，顺带把当前状态一起报回去
    private func registerPingObserver() {
        pingObservation = NotifyBridge.observePing { [weak self] in
            guard let self else { return }
            // 固定名回执：外部进程靠这条判断「扩展还活着」
            NotifyBridge.postAckPing()
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
            // 固定名回执：先回一条「指令已收到」，让悬浮窗能区分
            // 「扩展活着但没送到」和「扩展根本不在」这两种情况
            NotifyBridge.postAckTrig()

            // 悬浮窗为了防止单条通知丢失会连发三次，这里 2 秒内只认第一发
            let now = Date().timeIntervalSince1970
            self.stateLock.lock()
            let duplicate = now - self.lastTriggerAt < 2.0
            if !duplicate { self.lastTriggerAt = now }
            self.stateLock.unlock()
            if duplicate {
                NotifyBridge.postLog("TRIG_DUP")
                return
            }

            NotifyBridge.postLog("TRIG_SAVE_\(Int(target))")

            // 手输的任意秒数不一定能被 cfg 通道送到（cfg 只按 App 的档位枚举注册），
            // 所以收到指令时按需抬高保留窗口 —— 否则标称 300 秒、落盘只有 App 里那个 60 秒的量
            let needed = target + 20
            if self.currentRetention() < needed {
                self.setRetention(needed)
                NotifyBridge.postLog("RET_UP_\(Int(needed))")
            }            // 保留窗口必须盖住请求时长，否则 60 秒的请求落盘只有 50 秒的料，
            // 导出的视频就会短一截。多留 20 秒作为分片余量。
            let needed = target + 20
            if needed > self.currentRetention() {
                self.setRetention(needed)
                NotifyBridge.postLog("RET_UP_\(Int(needed))")
            }
            self.stateLock.lock()
            self.pendingSaveSeconds = target
            self.stateLock.unlock()
        }
    }

    /// 游戏内悬浮窗面板直接改码率。改完立刻切一段新分片，让新码率马上生效，
    /// 而不是等当前这段 10 秒录完 —— 用户改完几秒内就能感觉到。
    private func registerBitrateObserver() {
        bitrateObservation = NotifyBridge.observeBitrate { [weak self] mbps in
            guard let self else { return }
            let value = min(max(mbps, 1), 20)
            self.config.bitrateMbps = value
            RecorderConfigStore.save(self.config)
            NotifyBridge.postLog("BITRATE_\(Int(value))")
            self.rotateSegment(force: true)
        }
    }

    /// 游戏内悬浮窗面板直接改输出分辨率上限（0 = 原画质）。
    /// 只能向下缩：ReplayKit 给的源分辨率就是上限，选更高不会放大。
    private func registerResObserver() {
        resObservation = NotifyBridge.observeResCap { [weak self] height in
            guard let self else { return }
            let value = max(Int(height), 0)
            self.config.resolutionCapHeight = value
            RecorderConfigStore.save(self.config)
            NotifyBridge.postLog(value == 0 ? "RES_native" : "RES_\(value)p")
            self.rotateSegment(force: true)
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

    /// 从最新往回凑够需要的秒数。
    ///
    /// 返回选中的片段（旧 → 新）以及**最旧那段要裁掉多少秒**。
    /// 以前整段整段地拿，30 秒的请求会导出 30~40 秒 —— 多出来的是最后那段的余量。
    private func pickSegments(from files: [URL], seconds: Double) -> (urls: [URL], trimLeading: Double) {
        var picked: [URL] = []
        var total: Double = 0
        for url in files.reversed() {
            let duration = AVURLAsset(url: url).duration.seconds
            guard duration.isFinite, duration > 0.02 else { continue }
            picked.insert(url, at: 0)
            total += duration
            if total >= seconds { break }
        }
        return (picked, max(total - seconds, 0))
    }

    /// files 由调用方冻结后传入：导出要基于「按下保存那一刻」的片段集合，
    /// 不能等到导出时再列目录（那时录制线程已经又写了新片段）
    private func exportRecent(seconds: Double, files: [URL]) {
        NotifyBridge.postLog("SEGS_\(files.count)")
        let picked = pickSegments(from: files, seconds: seconds)
        NotifyBridge.postLog("PICK_\(picked.urls.count)_of_\(files.count)")
        guard !picked.urls.isEmpty else {
            NotifyBridge.postLog("SAVE_FAIL_nopick")
            NotifyBridge.postAckFail()
            return
        }
        export(picked: picked.urls, trimLeading: picked.trimLeading, completion: nil)
    }


    private func export(picked: [URL], trimLeading: Double = 0, completion: ((Bool) -> Void)?) {
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
        let trim = max(trimLeading, 0)
        for (index, url) in picked.enumerated() {
            let asset = AVURLAsset(url: url)
            guard let source = asset.tracks(withMediaType: .video).first else { continue }
            var start = CMTime.zero
            var duration = asset.duration
            if index == 0 && trim > 0.05 {
                // 最旧那段只取尾部，把多出来的秒数从头部裁掉，
                // 这样「保存 30 秒」导出的就是 30 秒，而不是 30~40 秒
                let keep = max(duration.seconds - trim, 0.2)
                start = CMTime(seconds: duration.seconds - keep, preferredTimescale: 600)
                duration = CMTime(seconds: keep, preferredTimescale: 600)
            }
            let range = CMTimeRange(start: start, duration: duration)
            try? videoTrack.insertTimeRange(range, of: source, at: cursor)
            if transform == nil { transform = source.preferredTransform }
            if let audioTrack, let audioSource = asset.tracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: audioSource, at: cursor)
            }
            cursor = cursor + duration
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
                NotifyBridge.postAckFail()
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
                    // 固定名回执：游戏内悬浮窗靠这条显示「已保存」
                    NotifyBridge.postAckDone()
                } else {
                    let ns = error as NSError?
                    NotifyBridge.postLog("PHOTO_FAIL_\(ns?.code ?? -1)")
                    NotifyBridge.postAckFail()
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
        NotifyBridge.postLog("STOP_SAVE_\(picked.urls.count)_of_\(files.count)")
        guard !picked.urls.isEmpty else { return }

        let sem = DispatchSemaphore(value: 0)
        export(picked: picked.urls) { ok in
            NotifyBridge.postLog(ok ? "STOP_OK" : "STOP_FAIL")
            sem.signal()
        }
        // 系统给 broadcastFinished 的时间有限，最多等 8 秒，等不到就算了
        _ = sem.wait(timeout: .now() + 8)
    }
}
