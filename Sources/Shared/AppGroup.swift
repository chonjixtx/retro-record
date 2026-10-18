import Foundation

public enum AppGroup {
    public static let identifier = AppIdentifiers.appGroup

    /// 备用公共目录候选。TrollStore / 越狱环境下 App 带 platform-application，
    /// 可以写沙盒外的固定路径，主 App 与扩展写同一处即可互通。
    /// 普通证书签名时这些路径都会被沙盒拒绝，自动回落。
    private static let fallbackCandidates = [
        "/var/mobile/Library/RetroRecorder",
        "/var/mobile/Documents/RetroRecorder",
        "/var/mobile/Media/RetroRecorder",
        "/var/mobile/RetroRecorder",
    ]

    /// 解析结果缓存：refresh 每 2 秒跑一次，不能每次都去建目录和写探针文件
    private static var cachedContainerURL: URL?
    private static var resolved = false
    private static var log: [String] = []

    private static func groupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var containerURL: URL? {
        if resolved { return cachedContainerURL }
        resolved = true
        log.removeAll()

        if let url = groupContainerURL() {
            log.append("App Group 正常：\(url.path)")
            cachedContainerURL = url
            return url
        }
        log.append("App Group 不可用")
        log.append("HOME：\(NSHomeDirectory())")

        for path in fallbackCandidates {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let probe = url.appendingPathComponent(".write-probe")
                try Data("ok".utf8).write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                log.append("可写：\(path)")
                cachedContainerURL = url
                return url
            } catch {
                log.append("拒绝：\(path)")
            }
        }
        cachedContainerURL = nil
        return nil
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

    /// 是否走了公共目录备用通道
    public static var isUsingFallback: Bool {
        groupContainerURL() == nil && containerURL != nil
    }

    /// 给界面看的简短诊断信息
    public static var diagnosisText: String {
        _ = containerURL
        if isUsingFallback {
            return "共享存储正常 · 公共目录（TrollStore 模式）"
        }
        if isAvailable {
            return "共享存储正常 · App Group"
        }
        return "共享存储不可用（无 App Group，公共目录也写不进）"
    }

    /// 详细诊断：把每条候选路径的成败都列出来，用于定位到底卡在哪
    public static var diagnosisDetail: String {
        _ = containerURL
        return log.joined(separator: "\n")
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
