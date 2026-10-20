import Foundation

public struct RecorderConfig: Equatable {
    /// 环形缓冲保留窗口（秒）。默认 600 秒 = 10 分钟
    public var retentionSeconds: Double
    /// 录制码率（Mbps）。1080p 建议 6
    public var bitrateMbps: Double
    public var microphoneEnabled: Bool
    /// 输出分辨率上限（高度像素）。0 = 原画质（跟随系统给的帧，不做缩放）。
    /// 注意只能向下缩：ReplayKit 给多少帧就最多录多少，选 4K 而源只有 1080p 时仍输出 1080p，
    /// 不会凭空放大 —— 放大只会让文件变大、画质不变。
    public var resolutionCapHeight: Int

    public static let `default` = RecorderConfig(
        retentionSeconds: 600,
        bitrateMbps: 6,
        microphoneEnabled: false,
        resolutionCapHeight: 0
    )

    public init(retentionSeconds: Double = 600, bitrateMbps: Double = 6,
                microphoneEnabled: Bool = false, resolutionCapHeight: Int = 0) {
        self.retentionSeconds = retentionSeconds
        self.bitrateMbps = bitrateMbps
        self.microphoneEnabled = microphoneEnabled
        self.resolutionCapHeight = resolutionCapHeight
    }

    public var clamped: RecorderConfig {
        var copy = self
        copy.retentionSeconds = min(max(copy.retentionSeconds, 10), 7200)
        copy.bitrateMbps = min(max(copy.bitrateMbps, 1), 20)
        copy.resolutionCapHeight = max(copy.resolutionCapHeight, 0)
        return copy
    }
}

public enum RecorderConfigStore {
    enum Key: String {
        case retentionSeconds
        case bitrateMbps
        case microphoneEnabled
        case resolutionCapHeight
    }

    public static func load() -> RecorderConfig {
        let retention = SharedPrefs.double(forKey: Key.retentionSeconds.rawValue)
        let bitrate = SharedPrefs.double(forKey: Key.bitrateMbps.rawValue)
        let mic = SharedPrefs.bool(forKey: Key.microphoneEnabled.rawValue)
        let cap = SharedPrefs.double(forKey: Key.resolutionCapHeight.rawValue)
        return RecorderConfig(
            retentionSeconds: retention ?? RecorderConfig.default.retentionSeconds,
            bitrateMbps: bitrate ?? RecorderConfig.default.bitrateMbps,
            microphoneEnabled: mic ?? RecorderConfig.default.microphoneEnabled,
            resolutionCapHeight: cap.map { Int($0) } ?? RecorderConfig.default.resolutionCapHeight
        )
    }

    public static func save(_ config: RecorderConfig) {
        let value = config.clamped
        SharedPrefs.set(value.retentionSeconds, forKey: Key.retentionSeconds.rawValue)
        SharedPrefs.set(value.bitrateMbps, forKey: Key.bitrateMbps.rawValue)
        SharedPrefs.set(value.microphoneEnabled, forKey: Key.microphoneEnabled.rawValue)
        SharedPrefs.set(Double(value.resolutionCapHeight), forKey: Key.resolutionCapHeight.rawValue)
    }
}
