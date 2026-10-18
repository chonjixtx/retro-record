import Foundation

/// 主 App 与录制扩展之间的轻量共享存储。
///
/// 不用 UserDefaults(suiteName:)：App Group 不可用时它会静默失败，
/// 而且 TrollStore 环境下也拿不到 group suite。
/// 这里直接落到 AppGroup.containerURL 下的文件，一个 key 一个文件，
/// 原子写，避免两个进程同时读写同一份 plist 造成覆盖。
public enum SharedPrefs {

    private static var directory: URL? {
        guard let base = AppGroup.containerURL else { return nil }
        let dir = base.appendingPathComponent("prefs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func fileURL(_ key: String) -> URL? {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directory?.appendingPathComponent(safe)
    }

    public static func set(_ value: Double, forKey key: String) {
        guard let url = fileURL(key) else { return }
        try? String(value).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func set(_ value: Bool, forKey key: String) {
        guard let url = fileURL(key) else { return }
        try? (value ? "1" : "0").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func double(forKey key: String) -> Double? {
        guard let url = fileURL(key),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func bool(forKey key: String) -> Bool? {
        guard let url = fileURL(key),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    public static func remove(forKey key: String) {
        guard let url = fileURL(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
