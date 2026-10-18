import AVFoundation
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

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 共享容器拿不到也继续录：此时走降级流程，
        // 分片写在本扩展沙盒里，用户点保存时由本进程自行拼接并直接存进相册。
        config = RecorderConfigStore.load().clamped
        _ = AppGroup.segmentsURL
        SegmentStore.prune(retentionSeconds: config.retentionSeconds)
        Heartbeat.setActive(true)
        Heartbeat.beat()
        registerSaveObserver()
    }

    override func broadcastPaused() {
        Heartbeat.beat()
    }

    override func broadcastResumed() {
        rotateSegment(force: true)
    }

    override func broadcastFinished() {
        rotateSegment(force: true)
        Heartbeat.setActive(false)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
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

    private func startNewSegment(with sampleBuffer: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 0, height > 0 else { return false }
        guard let output = SegmentStore.nextURL() else { return false }
        try? FileManager.default.removeItem(at: output)
        guard let newWriter = try? AVAssetWriter(url: output, fileType: .mp4) else { return false }

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

        guard newWriter.canAdd(input) else { return false }
        newWriter.add(input)
        guard newWriter.startWriting() else { return false }

        writer = newWriter
        videoInput = input
        pixelAdaptor = adaptor
        return true
    }

    private func rotateSegment(force: Bool) {
        guard let finishingWriter = writer else {
            resetSegmentState()
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

        guard finishingWriter.status == .writing else { return }
        finishingWriter.finishWriting { [weak self] in
            guard let self else { return }
            SegmentStore.prune(retentionSeconds: self.config.retentionSeconds)
            Heartbeat.beat()
        }
        if !force { Heartbeat.beat() }
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

    /// Darwin 通知只能传名字，所以把要保留的秒数编码进通知名
    private static let savePrefix = "com.retro.recorder.save."

    private func registerSaveObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let text = name.rawValue as String
                guard text.hasPrefix(SampleHandler.savePrefix) else { return }
                let seconds = Double(text.replacingOccurrences(of: SampleHandler.savePrefix, with: "")) ?? 600
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.handleSaveRequest(seconds: seconds)
            },
            nil,
            nil,
            .deliverImmediately
        )
    }

    private func handleSaveRequest(seconds: Double) {
        // 只有降级模式才由扩展导出；共享模式交给主 App 处理
        guard !AppGroup.isShared else { return }

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

    private func exportRecent(seconds: Double) {
        guard let dir = AppGroup.segmentsURL else { return }
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let files = all
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }
        guard !files.isEmpty else { return }

        // 从最新往回凑够需要的秒数
        var picked: [URL] = []
        var total: Double = 0
        for url in files.reversed() {
            let duration = AVURLAsset(url: url).duration.seconds
            guard duration.isFinite, duration > 0.05 else { continue }
            picked.insert(url, at: 0)
            total += duration
            if total >= seconds { break }
        }
        guard !picked.isEmpty else { return }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return }
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
        ) else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retro-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false

        exporter.exportAsynchronously {
            guard exporter.status == .completed else {
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            } completionHandler: { _, _ in
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
    }
}
