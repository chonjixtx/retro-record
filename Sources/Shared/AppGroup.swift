import Foundation

public enum AppGroup {
    public static let identifier = AppIdentifiers.appGroup

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var preferences: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// 共享容器是否真的拿得到。
    /// 重签时如果 entitlements 里的 application-groups 被剔除，或描述文件里没这个组，
    /// 主 App 与录制扩展就会各写各的沙盒 —— 表现为"系统在录但缓存永远是 0"。
    public static var isAvailable: Bool {
        containerURL != nil
    }

    /// 给界面看的简短诊断信息
    public static var diagnosisText: String {
        guard let url = containerURL else {
            return "共享存储不可用（App Group 未生效）"
        }
        return "共享存储正常 · \(url.lastPathComponent)"
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
