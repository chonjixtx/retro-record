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
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// 处理 retrorecord://save（可带 ?seconds=30/60/120）跨 App 保存入口。
    /// 由系统辅助触控/快捷指令唤起，详见 RecorderViewModel.saveFromDeepLink。
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "retrorecord" else { return }
        guard (url.host?.lowercased()) == "save" else { return }
        let seconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "seconds" })?
            .value
            .flatMap { Double($0) }
        model.saveFromDeepLink(seconds: seconds)
    }
}
