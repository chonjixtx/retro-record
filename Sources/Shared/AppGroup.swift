import Foundation

public enum AppGroup {
    public static let identifier = AppIdentifiers.appGroup

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var preferences: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    public static var segmentsURL: URL? {
        guard let base = containerURL else { return nil }
        let url = base.appendingPathComponent("segments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 导出的成品视频目录（主 App 侧可见，可用于分享 / 文件 App）
    public static var exportsURL: URL? {
        guard let base = containerURL else { return nil }
        let url = base.appendingPathComponent("exports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
