import Foundation

public struct RecorderConfig: Equatable {
    /// 环形缓冲保留窗口（秒）。默认 600 秒 = 10 分钟
    public var retentionSeconds: Double
    /// 录制码率（Mbps）。1080p 建议 6
    public var bitrateMbps: Double
    public var microphoneEnabled: Bool

    public static let `default` = RecorderConfig(
        retentionSeconds: 600,
        bitrateMbps: 6,
        microphoneEnabled: false
    )

    public init(retentionSeconds: Double = 600, bitrateMbps: Double = 6, microphoneEnabled: Bool = false) {
        self.retentionSeconds = retentionSeconds
        self.bitrateMbps = bitrateMbps
        self.microphoneEnabled = microphoneEnabled
    }

    public var clamped: RecorderConfig {
        var copy = self
        copy.retentionSeconds = min(max(copy.retentionSeconds, 10), 7200)
        copy.bitrateMbps = min(max(copy.bitrateMbps, 1), 20)
        return copy
    }
}

public enum RecorderConfigStore {
    enum Key: String {
        case retentionSeconds
        case bitrateMbps
        case microphoneEnabled
    }

    public static func load() -> RecorderConfig {
        let retention = SharedPrefs.double(forKey: Key.retentionSeconds.rawValue)
        let bitrate = SharedPrefs.double(forKey: Key.bitrateMbps.rawValue)
        let mic = SharedPrefs.bool(forKey: Key.microphoneEnabled.rawValue)
        return RecorderConfig(
            retentionSeconds: retention ?? RecorderConfig.default.retentionSeconds,
            bitrateMbps: bitrate ?? RecorderConfig.default.bitrateMbps,
            microphoneEnabled: mic ?? RecorderConfig.default.microphoneEnabled
        )
    }

    public static func save(_ config: RecorderConfig) {
        let value = config.clamped
        SharedPrefs.set(value.retentionSeconds, forKey: Key.retentionSeconds.rawValue)
        SharedPrefs.set(value.bitrateMbps, forKey: Key.bitrateMbps.rawValue)
        SharedPrefs.set(value.microphoneEnabled, forKey: Key.microphoneEnabled.rawValue)
    }
}
