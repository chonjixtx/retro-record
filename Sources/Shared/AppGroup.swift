import Foundation

public enum AppGroup {
    public static let identifier = AppIdentifiers.appGroup

    /// TrollStore / 越狱环境下，主 App 与扩展都能读写的公共目录。
    /// 正常证书签名时这个路径写不进去（沙盒会拒绝），会自动回落到 App Group。
    private static let trollStoreFallbackPath = "/var/mobile/Library/RetroRecorder"

    public static var containerURL: URL? {
        // 1) 标准路径：App Group（需要付费证书 + 描述文件含该 group）
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // 2) 备用路径：TrollStore 安装时 App 带 platform-application 权限，
        //    可以访问沙盒外的公共目录，两个进程写同一处即可互通。
        let fallback = URL(fileURLWithPath: trollStoreFallbackPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            let probe = fallback.appendingPathComponent(".write-probe")
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return fallback
        } catch {
            return nil
        }
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

    /// 是否走了 TrollStore 的公共目录备用通道
    public static var isUsingFallback: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) == nil
            && containerURL != nil
    }

    /// 给界面看的简短诊断信息
    public static var diagnosisText: String {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return "共享存储正常 · App Group（\(groupURL.lastPathComponent)）"
        }
        if containerURL != nil {
            return "共享存储正常 · 公共目录（TrollStore 模式）"
        }
        return "共享存储不可用（既没有 App Group 权限，也无法写入公共目录）"
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
