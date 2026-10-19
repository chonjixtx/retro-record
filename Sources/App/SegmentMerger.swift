import AVFoundation
import Foundation

public enum ExportQuality: String, CaseIterable, Identifiable {
    case p1080
    case p720
    case native

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .p1080: return "1080P"
        case .p720: return "720P"
        case .native: return "原生分辨率"
        }
    }

    public var presetName: String {
        switch self {
        case .p1080: return AVAssetExportPreset1920x1080
        case .p720: return AVAssetExportPreset1280x720
        case .native: return AVAssetExportPresetPassthrough
        }
    }
}

enum MergerError: LocalizedError {
    case noSegments
    case readFailed(failed: Int, total: Int)
    case cannotBuildComposition
    case cannotCreateExporter
    case exportFailed(Error?)
    case installFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有缓存到任何画面，先在系统弹层里点一次开始录制"
        case .readFailed(let failed, let total):
            return "读取分片失败：\(total) 个分片里 \(failed) 个读不出来。多半是录制扩展还在写最新一片，稍等两秒再保存；反复失败就清空缓冲重录"
        case .cannotBuildComposition: return "无法组装视频轨道：所有分片都无法插入轨道（文件可能损坏），请清空缓冲重录"
        case .cannotCreateExporter: return "无法创建导出器，试试切换导出画质"
        case .exportFailed(let error): return "导出失败：\(error.map { Self.describe($0) } ?? "未知错误")"
        case .installFailed(let reason): return "视频已拼接成功，但移入保存目录失败：\(reason)"
        case .cancelled: return "导出已取消"
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription)（\(ns.domain) / \(ns.code)）"
    }
}

/// 把环形缓冲里"最近 N 秒"的片段拼成一条完整 mp4
enum SegmentMerger {
    static func exportLast(seconds: Double, quality: ExportQuality) async throws -> URL {
        let segments = SegmentStore.allSegments()
        guard !segments.isEmpty else { throw MergerError.noSegments }
        LogBridge.local("EXP_SEG_\(segments.count)_REQ_\(Int(seconds))s")

        // 第一步：把要用的分片拷进 App 自己的临时目录。
        // 导出实际由系统进程 mediaserverd 代劳，TrollStore / 自签环境下它对
        // App Group 共享容器没有读写权限（读不到源文件、写不了产物都会报
        // AVFoundationErrorDomain -11838「操作已停止」）。
        // App 进程自己读写共享容器没问题，所以由 App 先把料备好、最后再搬回去。
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("retro-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        struct Item {
            let asset: AVURLAsset
            let duration: CMTime
        }

        var items: [Item] = []
        var readFailures = 0
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            // 正在写入的那一片还没有 moov，取 duration 会抛错，直接跳过
            let duration = await AssetCompat.duration(of: asset)
            guard duration.isValid, duration.seconds > 0.05 else { continue }
            let copy = workDir.appendingPathComponent(segment.url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: segment.url, to: copy)
            } catch {
                readFailures += 1
                continue
            }
            items.append(Item(asset: AVURLAsset(url: copy), duration: duration))
        }
        if items.isEmpty {
            LogBridge.local("EXP_READFAIL_\(readFailures)_OF_\(segments.count)")
            throw MergerError.readFailed(failed: readFailures, total: segments.count)
        }

        // 从最新的一段往回取，直到凑满需要的秒数
        var plan: [(Item, CMTimeRange)] = []
        var remaining = max(seconds, 1)
        // 直通模式不做重编码，切点必须落在关键帧（分段边界）上，否则开头会黑屏
        let alignToSegment = (quality == .native)
        for item in items.reversed() {
            let total = item.duration.seconds
            if remaining >= total {
                plan.append((item, CMTimeRange(start: .zero, duration: item.duration)))
                remaining -= total
            } else if alignToSegment {
                plan.append((item, CMTimeRange(start: .zero, duration: item.duration)))
                remaining = 0
            } else {
                let start = CMTime(seconds: total - remaining, preferredTimescale: 600)
                plan.append((item, CMTimeRange(start: start, duration: CMTime(seconds: remaining, preferredTimescale: 600))))
                remaining = 0
            }
            if remaining <= 0 { break }
        }
        plan.reverse()
        guard !plan.isEmpty else { throw MergerError.noSegments }

        // 预取每个分片的音视频轨。关键修复：分片在静音时段可能没有音频轨，
        // 若 composition 的音频轨出现「空洞」（有轨但时长对不上），
        // AVAssetExportSession 会报 AVFoundationErrorDomain -11800。
        // 因此：所有分片都有音频轨才建音频轨，否则导出无声视频。
        struct Planned {
            let range: CMTimeRange
            let video: AVAssetTrack
            let audio: AVAssetTrack?
            let transform: CGAffineTransform
        }
        var planned: [Planned] = []
        var allHaveAudio = true
        for (item, range) in plan {
            let videos = await AssetCompat.videoTracks(of: item.asset)
            guard let video = videos.first else { continue }
            let audios = await AssetCompat.audioTracks(of: item.asset)
            if audios.first == nil { allHaveAudio = false }
            let transform = await AssetCompat.preferredTransform(of: video)
            let insertRange = range.intersection(video.timeRange) ?? range
            planned.append(Planned(range: insertRange, video: video, audio: audios.first, transform: transform))
        }
        LogBridge.local("EXP_PLAN_\(planned.count)_AUD_\(allHaveAudio ? 1 : 0)")
        guard !planned.isEmpty else {
            LogBridge.local("EXP_PLAN_EMPTY")
            throw MergerError.cannotBuildComposition
        }

        func buildComposition(withAudio: Bool) throws -> AVMutableComposition {
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MergerError.cannotBuildComposition
            }
            let audioTrack = withAudio
                ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                : nil
            var cursor = CMTime.zero
            var insertedCount = 0
            for (idx, p) in planned.enumerated() {
                do {
                    try videoTrack.insertTimeRange(p.range, of: p.video, at: cursor)
                    insertedCount += 1
                } catch {
                    // 逐片记录失败原因：错误域/码 + 请求范围与轨道实际范围，用于远程定位
                    let ns = error as NSError
                    LogBridge.local("EXP_INS_FAIL_\(idx)_\(ns.domain)_\(ns.code)_req\(Int(p.range.start.seconds))d\(Int(p.range.duration.seconds))_vt\(Int(p.video.timeRange.duration.seconds))")
                    continue
                }
                if let audioTrack, let audio = p.audio {
                    let audioRange = p.range.intersection(audio.timeRange) ?? p.range
                    try? audioTrack.insertTimeRange(audioRange, of: audio, at: cursor)
                }
                cursor = cursor + p.range.duration
            }
            LogBridge.local("EXP_INS_OK_\(insertedCount)_OF_\(planned.count)")
            guard insertedCount > 0 else { throw MergerError.cannotBuildComposition }
            videoTrack.preferredTransform = planned.first?.transform ?? .identity
            return composition
        }

        let outputURL = try makeOutputURL()
        // 多级重试：用户画质 → 直通 → 直通+去音频，尽量救回每一次保存
        var attempts: [(ExportQuality, Bool)] = [(quality, allHaveAudio), (.native, allHaveAudio)]
        if allHaveAudio { attempts.append((.native, false)) }
        var lastError: Error?
        for (q, withAudio) in attempts {
            do {
                let composition = try buildComposition(withAudio: withAudio)
                try await runExport(composition: composition, quality: q, outputURL: outputURL)
                LogBridge.local("EXP_OK_\(q.rawValue)")
                return try installToExports(from: outputURL)
            } catch MergerError.cancelled {
                throw MergerError.cancelled
            } catch {
                let ns = error as NSError
                LogBridge.local("EXP_TRY_\(q.rawValue)_FAIL_\(ns.domain)_\(ns.code)")
                lastError = error
            }
        }
        // 保底：拼接导出全部失败时，逐片直通导出到保存目录，至少把画面留住
        if let exportsDir = AppGroup.exportsURL {
            LogBridge.local("EXP_FALLBACK_START")
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmmss"
            var savedCount = 0
            var lastSavedURL: URL?
            for (idx, item) in items.enumerated() {
                let out = exportsDir.appendingPathComponent("回溯_分片\(formatter.string(from: Date()))-\(idx).mp4")
                guard let ex = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetPassthrough) else { continue }
                ex.outputURL = out
                ex.outputFileType = .mp4
                do {
                    try await ex.runExportToOutputURL()
                    savedCount += 1
                    lastSavedURL = out
                    LogBridge.local("EXP_FALLBACK_OK_\(idx)")
                } catch {
                    let ns = error as NSError
                    LogBridge.local("EXP_FALLBACK_FAIL_\(idx)_\(ns.domain)_\(ns.code)")
                }
            }
            if savedCount > 0, let url = lastSavedURL {
                LogBridge.local("EXP_FALLBACK_SAVED_\(savedCount)")
                return url
            }
        }
        throw lastError ?? MergerError.exportFailed(nil)
    }

    private static func runExport(
        composition: AVMutableComposition,
        quality: ExportQuality,
        outputURL: URL
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: quality.presetName) else {
            throw MergerError.cannotCreateExporter
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.runExportToOutputURL()
    }

    private static func makeOutputURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "回溯_\(formatter.string(from: Date())).mp4"
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// 导出成功后，由 App 进程（不是 mediaserverd）把成品搬进共享容器的 exports 目录
    private static func installToExports(from tmpURL: URL) throws -> URL {
        guard let exportsDir = AppGroup.exportsURL else {
            throw MergerError.installFailed("App Group exports 目录不可用")
        }
        let dest = exportsDir.appendingPathComponent(tmpURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
        } catch {
            // 兜底：移动失败就复制一份过去
            do {
                try FileManager.default.copyItem(at: tmpURL, to: dest)
                try? FileManager.default.removeItem(at: tmpURL)
            } catch {
                LogBridge.local("EXP_INSTALL_FAIL \(error.localizedDescription)")
                throw MergerError.installFailed((error as NSError).localizedDescription)
            }
        }
        LogBridge.local("EXP_INSTALLED")
        return dest
    }
}

extension AVAssetExportSession {
    /// 名字不能叫 export()：iOS 18 SDK 自带 async 版 export()，同名会歧义。
    /// 这里用回调版包一层，兼容 iOS 16 部署目标。
    func runExportToOutputURL() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: MergerError.cancelled)
                default:
                    continuation.resume(throwing: MergerError.exportFailed(self.error))
                }
            }
        }
    }
}
