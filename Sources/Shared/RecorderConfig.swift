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
        guard let prefs = AppGroup.preferences else { return .default }
        let retention = prefs.object(forKey: Key.retentionSeconds.rawValue) as? Double
        let bitrate = prefs.object(forKey: Key.bitrateMbps.rawValue) as? Double
        let mic = prefs.object(forKey: Key.microphoneEnabled.rawValue) as? Bool
        return RecorderConfig(
            retentionSeconds: retention ?? RecorderConfig.default.retentionSeconds,
            bitrateMbps: bitrate ?? RecorderConfig.default.bitrateMbps,
            microphoneEnabled: mic ?? RecorderConfig.default.microphoneEnabled
        )
    }

    public static func save(_ config: RecorderConfig) {
        guard let prefs = AppGroup.preferences else { return }
        let value = config.clamped
        prefs.set(value.retentionSeconds, forKey: Key.retentionSeconds.rawValue)
        prefs.set(value.bitrateMbps, forKey: Key.bitrateMbps.rawValue)
        prefs.set(value.microphoneEnabled, forKey: Key.microphoneEnabled.rawValue)
    }
}
