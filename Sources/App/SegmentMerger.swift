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
    case cannotBuildComposition
    case cannotCreateExporter
    case exportFailed(Error?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSegments: return "还没有缓存到任何画面，先在系统弹层里点一次开始录制"
        case .cannotBuildComposition: return "无法组装视频轨道"
        case .cannotCreateExporter: return "无法创建导出器，试试切换导出画质"
        case .exportFailed(let error): return "导出失败：\(error?.localizedDescription ?? "未知错误")"
        case .cancelled: return "导出已取消"
        }
    }
}

/// 把环形缓冲里"最近 N 秒"的片段拼成一条完整 mp4
enum SegmentMerger {
    static func exportLast(seconds: Double, quality: ExportQuality) async throws -> URL {
        let segments = SegmentStore.allSegments()
        guard !segments.isEmpty else { throw MergerError.noSegments }

        struct Item {
            let asset: AVURLAsset
            let duration: CMTime
        }

        var items: [Item] = []
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            // 正在写入的那一片还没有 moov，取 duration 会抛错，直接跳过
            let duration = await AssetCompat.duration(of: asset)
            guard duration.isValid, duration.seconds > 0.05 else { continue }
            items.append(Item(asset: asset, duration: duration))
        }
        guard !items.isEmpty else { throw MergerError.noSegments }

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
        for (item, range) in plan {
            let videoSources = await AssetCompat.videoTracks(of: item.asset)
            guard let source = videoSources.first else { continue }

            do {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
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
                    try? audioTrack.insertTimeRange(range, of: audioSource, at: cursor)
                }
            }
            cursor = cursor + range.duration
        }
        videoTrack.preferredTransform = preferredTransform ?? .identity

        let outputURL = try makeOutputURL()
        guard let exporter = AVAssetExportSession(asset: composition, presetName: quality.presetName) else {
            throw MergerError.cannotCreateExporter
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.runExportToOutputURL()
        return outputURL
    }

    private static func makeOutputURL() throws -> URL {
        guard let dir = AppGroup.exportsURL else { throw MergerError.cannotBuildComposition }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "回溯_\(formatter.string(from: Date())).mp4"
        return dir.appendingPathComponent(name)
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
