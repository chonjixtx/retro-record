import AVFoundation
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

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 共享容器拿不到就直接报错退出。
        // 否则会变成"系统显示在录、主 App 永远 0 秒"的静默失败，用户根本没法定位。
        guard AppGroup.isAvailable else {
            let error = NSError(
                domain: "RetroRecorder",
                code: -100,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "无法访问共享存储（App Group 未生效）。\n请用支持 App Group 的证书重新签名，或在签名工具里保留 application-groups 权限。"
                ]
            )
            finishBroadcastWithError(error)
            return
        }

        config = RecorderConfigStore.load().clamped
        _ = AppGroup.segmentsURL
        SegmentStore.prune(retentionSeconds: config.retentionSeconds)
        Heartbeat.setActive(true)
        Heartbeat.beat()
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
}
