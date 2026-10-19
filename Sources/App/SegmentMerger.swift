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
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有缓存到任何画面，先在系统弹层里点一次开始录制"
        case .readFailed(let failed, let total):
            return "读取分片失败：\(total) 个分片里 \(failed) 个读不出来。多半是录制扩展还在写最新一片，稍等两秒再保存；反复失败就清空缓冲重录"
        case .cannotBuildComposition: return "无法组装视频轨道：所有分片都无法插入轨道（文件可能损坏），请清空缓冲重录"
        case .cannotCreateExporter: return "无法创建导出器，试试切换导出画质"
        case .exportFailed(let error): return "导出失败：\(error.map { Self.describe($0) } ?? "未知错误")"
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

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergerError.cannotBuildComposition
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var preferredTransform: CGAffineTransform?
        var insertedCount = 0
        for (item, range) in plan {
            let videoSources = await AssetCompat.videoTracks(of: item.asset)
            guard let source = videoSources.first else { continue }

            // 轨道实际时长可能比 asset duration 短一点，超范围插入会抛错，先裁剪
            let insertRange = range.intersection(source.timeRange) ?? range
            do {
                try videoTrack.insertTimeRange(insertRange, of: source, at: cursor)
                insertedCount += 1
            } catch {
                // 某一片损坏就跳过它，不要让整次保存失败
                continue
            }
            if preferredTransform == nil {
                preferredTransform = await AssetCompat.preferredTransform(of: source)
            }
            if let audioTrack {
                let audioSources = await AssetCompat.audioTracks(of: item.asset)
                if let audioSource = audioSources.first {
                    let audioRange = insertRange.intersection(audioSource.timeRange) ?? insertRange
                    try? audioTrack.insertTimeRange(audioRange, of: audioSource, at: cursor)
                }
            }
            cursor = cursor + insertRange.duration
        }
        guard insertedCount > 0 else { throw MergerError.cannotBuildComposition }
        videoTrack.preferredTransform = preferredTransform ?? .identity

        let outputURL = try makeOutputURL()
        // 首选用户选的画质；失败自动用直通模式（不重编码）再试一次，
        // 排除画质预设与源不兼容导致的失败
        do {
            try await runExport(composition: composition, quality: quality, outputURL: outputURL)
        } catch {
            if quality != .native {
                try await runExport(composition: composition, quality: .native, outputURL: outputURL)
            } else {
                throw error
            }
        }
        return try installToExports(from: outputURL)
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
        guard let exportsDir = AppGroup.exportsURL else { throw MergerError.cannotBuildComposition }
        let dest = exportsDir.appendingPathComponent(tmpURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
        } catch {
            // 兜底：移动失败就复制一份过去
            try FileManager.default.copyItem(at: tmpURL, to: dest)
            try? FileManager.default.removeItem(at: tmpURL)
        }
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
