import UIKit
import UserNotifications

/// 主 App 代理（通过 UIApplicationDelegateAdaptor 挂到 SwiftUI 生命周期上，不影响主 Scene 管理）。
///
/// 职责：
/// 1. 启动时初始化「通知栏一键保存」的通知代理与分类；
/// 2. 全局悬浮球开关自愈：冷启动时若上次开关是 ON，复位为 OFF（本次不会自动重建私有 Scene，
///    避免「开关显示开、桌面却没球」的错位状态；也避免一开屏就冻结/闪退）；
/// 3. 锚定 Scene 的空代理配置（仅用户手动打开全局球开关后才会用到）。
final class RetroAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 与 OverlayBridge 里的 kOverlaySceneIdentifier 保持一致
    static let overlaySceneIdentifier = "retrooverlay"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 通知栏一键保存：注册分类 + 请求权限 + 接管动作回调
        SaveNotification.registerCategory()
        SaveNotification.requestAuthorization()
        UNUserNotificationCenter.current().delegate = self

        // 全局悬浮球（私有 FrontBoard Scene）不在启动时创建——它在部分机型/iOS 会冻结或闪退。
        // 冷启动说明上次的进程已经没了，私有 Scene 不可能还在；把开关复位为 OFF，
        // 避免「开关是开着的、但桌面没有球」的错位状态。
        if UserDefaults.standard.bool(forKey: "retro.bg.overlay") {
            UserDefaults.standard.set(false, forKey: "retro.bg.overlay")
            UserDefaults.standard.set(true, forKey: "retro.bg.overlay.wasOn")
        }
        return true
    }

    // MARK: - 通知栏「保存最近片段」被点击

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == SaveNotification.actionID {
            SaveTrigger.shared.fire()
        }
        completionHandler()
    }

    /// App 在前台时也把通知横幅显示出来（录制时通常已在后台，此条为兜底）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting sceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let identifier = sceneSession.persistentIdentifier

        // 锚定 Scene：空代理、零窗口。它只负责「存在」，显示由无 Scene 的独立窗口负责。
        // 不能给 delegateClass = nil：SwiftUI 生命周期下会由 SwiftUI 默认代理接管，
        // 把主界面塞进这个 Scene。EmptySceneDelegate 不实现 willConnectTo，即零窗口。
        if identifier == Self.overlaySceneIdentifier {
            let config = UISceneConfiguration(name: "OverlayAnchor", sessionRole: sceneSession.role)
            config.sceneClass = UIWindowScene.self
            config.delegateClass = EmptySceneDelegate.self
            return config
        }

        // 主 Scene：不指定 delegateClass，交回 SwiftUI 默认处理（WindowGroup 正常渲染）
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if identifier == mainID || identifier.isEmpty || identifier == "default" {
            return UISceneConfiguration(name: "Default Configuration", sessionRole: sceneSession.role)
        }

        // 其他来路不明的 Scene：空场景兜底，绝不渲染内容
        let config = UISceneConfiguration(name: "Empty", sessionRole: sceneSession.role)
        config.sceneClass = UIWindowScene.self
        config.delegateClass = EmptySceneDelegate.self
        return config
    }
}
