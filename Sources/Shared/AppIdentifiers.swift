import Foundation

public enum AppIdentifiers {
    /// App Group：主 App 与录制扩展之间共享视频片段的唯一通道
    /// 全能签重签时若剔除了 application-groups 权限，环形缓冲会失效（能录、取不出）
    public static let appGroup = "group.com.retro.recorder"
    public static let application = "com.retro.recorder"
    public static let broadcastUploadExtension = "com.retro.recorder.broadcast"
    public static let widgetExtension = "com.retro.recorder.widget"
}
