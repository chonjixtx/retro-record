import Foundation

/// 主 App 与录制扩展之间能用哪种存储
public enum StorageMode {
    /// 标准：App Group 共享容器（需要付费证书 + 描述文件含该 group）
    case appGroup
    /// TrollStore / 越狱：沙盒外的公共目录
    case publicDirectory
    /// 降级：只能写各自沙盒。此时扩展无法把文件交给主 App，
    /// 改为由扩展自己拼接并直接存进系统相册。
    case localSandbox
}

public enum AppGroup {
    public static let identifier = AppIdentifiers.appGroup

    /// 备用公共目录候选。TrollStore / 越狱环境下 App 带 platform-application，
    /// 可以写沙盒外的固定路径，主 App 与扩展写同一处即可互通。
    private static let fallbackCandidates = [
        "/var/mobile/Library/RetroRecorder",
        "/private/var/mobile/Library/RetroRecorder",
        "/var/mobile/Documents/RetroRecorder",
        "/var/mobile/Media/RetroRecorder",
        "/tmp/RetroRecorder",
        "/var/mobile/RetroRecorder",
    ]

    /// 解析结果缓存：refresh 每 2 秒跑一次，不能每次都去建目录和写探针文件
    private static var cachedContainerURL: URL?
    private static var cachedMode: StorageMode = .localSandbox
    private static var resolved = false
    private static var log: [String] = []

    private static func groupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 解析一次，之后走缓存
    private static func resolve() {
        guard !resolved else { return }
        resolved = true
        log.removeAll()

        // 全能签变体：编译期就决定不用 App Group，也不再试探公共目录
        // （沙盒下那些路径必然写不进去，试探纯属浪费时间）。
        // 直接固定为降级模式，保存由录制扩展自行写相册。
        if RetroEnv.noAppGroup {
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                cachedContainerURL = caches
                cachedMode = .localSandbox
                log.append("全能签变体：不使用 App Group")
                log.append(caches.path)
            } else {
                cachedContainerURL = nil
                cachedMode = .localSandbox
                log.append("全能签变体：无任何可写目录")
            }
            return
        }

        if let url = groupContainerURL() {
            cachedContainerURL = url
            cachedMode = .appGroup
            log.append("App Group 正常：\(url.path)")
            return
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
                cachedContainerURL = url
                cachedMode = .publicDirectory
                log.append("可写：\(path)")
                return
            } catch {
                log.append("拒绝：\(path)")
            }
        }

        // 最后兜底：自己的 caches 目录。
        // 主 App 与扩展各自独立，无法互通 —— 此时走"扩展自行导出到相册"的降级流程。
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cachedContainerURL = caches
            cachedMode = .localSandbox
            log.append("降级：仅本进程沙盒可写")
            log.append(caches.path)
        } else {
            cachedContainerURL = nil
            cachedMode = .localSandbox
            log.append("无任何可写目录")
        }
    }

    public static var containerURL: URL? {
        resolve()
        return cachedContainerURL
    }

    public static var mode: StorageMode {
        resolve()
        return cachedMode
    }

    /// 录制扩展与主 App 是否真的能共享文件
    public static var isShared: Bool {
        mode != .localSandbox
    }

    /// 兼容旧调用
    public static var isAvailable: Bool { isShared }

    public static var preferences: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// 给界面看的简短诊断信息
    public static var diagnosisText: String {
        switch mode {
        case .appGroup:
            return "共享存储正常 · App Group"
        case .publicDirectory:
            return "共享存储正常 · 公共目录（TrollStore 模式）"
        case .localSandbox:
            if RetroEnv.noAppGroup {
                return "全能签版：不依赖 App Group，分片存于录制扩展沙盒，保存后直接写入相册"
            }
            return "降级模式：无法跨进程共享，保存将由录制扩展直接写入相册"
        }
    }

    /// 详细诊断：把每条候选路径的成败都列出来，用于定位到底卡在哪
    public static var diagnosisDetail: String {
        resolve()
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
