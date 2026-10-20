import Foundation

/// 录制扩展把关键事件落盘，供主 App 事后读取。
///
/// 为什么需要这个文件：用户在游戏里点保存按钮时，主 App 通常已经被系统挂起，
/// 而 Darwin 通知唤不醒挂起进程 —— 那几条日志就永远丢了，等用户打完一局切回
/// App，诊断区空空如也，什么也排查不了。
///
/// 落盘到共享目录后，扩展写、主 App 读，方向天然可靠：不管主 App 当时是活着
/// 还是挂起，事后都能看到扩展到底收到了什么、卡在哪一步。
public enum ExtLogFile {
    private static let fileName = "ext-events.log"
    private static let maxBytes = 256 * 1024
    private static let lock = NSLock()

    private static var fileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    public static func append(_ raw: String) {
        guard let url = fileURL else { return }
        let line = clockText() + " " + raw.replacingOccurrences(of: "\n", with: " ") + "\n"
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // 超过上限就重写成后半段，避免无限增长
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64,
               size > maxBytes {
                let keep = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let tail = keep.suffix(maxBytes / 2)
                try? tail.write(to: url, atomically: false, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    public static func readTail(_ count: Int = 30) -> [String] {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }

    public static func clear() {
        guard let url = fileURL else { return }
        try? Data().write(to: url)
    }

    private static func clockText() -> String {
        let total = Int(Date().timeIntervalSince1970) % 86400
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}
