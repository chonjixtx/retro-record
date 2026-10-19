import UIKit

/// 主 App 代理（通过 UIApplicationDelegateAdaptor 挂到 SwiftUI 生命周期上，不影响主 Scene 管理）。
///
/// 两件事：
/// 1. 启动时创建全局悬浮窗的浮动 Scene（仅 TrollStore 环境有意义）；
/// 2. 拦截浮动 Scene 的连接请求，交给 OverlaySceneDelegate 装悬浮球窗口。
final class RetroAppDelegate: NSObject, UIApplicationDelegate {
    /// 与 OverlayBridge 里的 kOverlaySceneIdentifier 保持一致
    static let overlaySceneIdentifier = "retrooverlay"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 全能签变体没有 platform-application 权限，全局悬浮窗不可用，不启动
        if RetroEnv.backgroundOverlayAvailable {
            OverlayBridge.startOverlayScene()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting sceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let identifier = sceneSession.persistentIdentifier

        // 浮动 Scene：交给专门的代理装悬浮球
        if identifier == Self.overlaySceneIdentifier {
            let config = UISceneConfiguration(name: "Overlay", sessionRole: sceneSession.role)
            config.sceneClass = UIWindowScene.self
            config.delegateClass = OverlaySceneDelegate.self
            return config
        }

        // 主 Scene：不指定 delegateClass，交回 SwiftUI 默认处理（WindowGroup 正常渲染）
        let mainID = Bundle.main.bundleIdentifier ?? ""
        if identifier == mainID || identifier.isEmpty || identifier == "default" {
            return UISceneConfiguration(name: "Default Configuration", sessionRole: sceneSession.role)
        }

        // 其他来路不明的 Scene：空窗口兜底，绝不渲染内容
        let config = UISceneConfiguration(name: "Empty", sessionRole: sceneSession.role)
        config.sceneClass = UIWindowScene.self
        config.delegateClass = EmptySceneDelegate.self
        return config
    }
}
