import Foundation

/// 心跳：录制扩展每落一段就打一次点，主 App 据此判断"录制还在不在"
/// iOS 主 App 进后台会被挂起，无法与扩展实时通信，只能靠共享 UserDefaults 轮询
public enum Heartbeat {
    static let beatKey = "retro.recorder.heartbeat"
    static let activeKey = "retro.recorder.active"

    /// 超过这个秒数没心跳，判定为断流（锁屏 / 被系统回收 / 用户手动停止）
    public static let stallThreshold: TimeInterval = 25

    public static func beat() {
        AppGroup.preferences?.set(Date().timeIntervalSince1970, forKey: beatKey)
    }

    public static func setActive(_ active: Bool) {
        AppGroup.preferences?.set(active, forKey: activeKey)
    }

    public static func isRecording(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let prefs = AppGroup.preferences, prefs.bool(forKey: activeKey) else { return false }
        let last = prefs.double(forKey: beatKey)
        guard last > 0 else { return false }
        return (now - last) <= stallThreshold
    }

    public static func lastBeat() -> TimeInterval {
        AppGroup.preferences?.double(forKey: beatKey) ?? 0
    }

    public static func wasInterrupted(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let prefs = AppGroup.preferences, prefs.bool(forKey: activeKey) else { return false }
        let last = prefs.double(forKey: beatKey)
        return last > 0 && (now - last) > stallThreshold
    }

    public static func clearInterruptedFlag() {
        setActive(false)
    }
}
