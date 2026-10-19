import SwiftUI

@main
@MainActor
struct RetroRecordApp: App {
    // 主 App 代理：负责启动全局悬浮窗的浮动 Scene。
    // 不影响 SwiftUI 对主 Scene 的管理（configurationForConnecting 对主场景返回默认配置）。
    @UIApplicationDelegateAdaptor(RetroAppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
