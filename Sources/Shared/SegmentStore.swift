import Foundation

public struct SegmentFile: Identifiable, Comparable {
    public let url: URL
    public let timestamp: TimeInterval

    public var id: URL { url }

    public init(url: URL, timestamp: TimeInterval) {
        self.url = url
        self.timestamp = timestamp
    }

    public static func < (lhs: SegmentFile, rhs: SegmentFile) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

/// 分段环形缓冲：录制扩展每 10 秒落一个 mp4，主 App 只保留最近 N 秒的片段
public enum SegmentStore {
    /// 单个片段时长（秒）。段越短，回溯裁剪越精确，但文件数越多
    public static let segmentSeconds: Double = 10

    public static func nextURL() -> URL? {
        guard let dir = AppGroup.segmentsURL else { return nil }
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return dir.appendingPathComponent("seg_\(millis).mp4")
    }

    public static func allSegments() -> [SegmentFile] {
        guard let dir = AppGroup.segmentsURL else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { url -> SegmentFile? in
                let name = url.deletingPathExtension().lastPathComponent
                let raw = name.replacingOccurrences(of: "seg_", with: "")
                guard let millis = Double(raw) else { return nil }
                return SegmentFile(url: url, timestamp: millis / 1000.0)
            }
            .sorted()
    }

    /// 删除超出保留窗口的旧片段。录制扩展每完成一段就调用一次
    public static func prune(retentionSeconds: Double) {
        let segments = allSegments()
        guard let newest = segments.last else { return }
        let window = max(retentionSeconds, segmentSeconds)
        let cutoff = newest.timestamp - window
        let maxCount = Int(ceil(window / segmentSeconds)) + 3

        var keep = segments.filter { $0.timestamp >= cutoff }
        if keep.count > maxCount {
            keep = Array(keep.suffix(maxCount))
        }
        let keepSet = Set(keep.map { $0.url })
        for segment in segments where !keepSet.contains(segment.url) {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    public static func removeAll() {
        for segment in allSegments() {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    public static func totalSizeBytes() -> UInt64 {
        let manager = FileManager.default
        return allSegments().reduce(UInt64(0)) { total, segment in
            let size = (try? manager.attributesOfItem(atPath: segment.url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return total + size
        }
    }
}

public enum ExportStore {
    public static func allExports() -> [URL] {
        guard let dir = AppGroup.exportsURL else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return l > r
            }
    }

    public static func prune(keepingMostRecent limit: Int = 30) {
        let files = allExports()
        guard files.count > limit else { return }
        for file in files.dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
