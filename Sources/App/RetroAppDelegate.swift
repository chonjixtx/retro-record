import UIKit

/// 主 App 代理（通过 UIApplicationDelegateAdaptor 挂到 SwiftUI 生命周期上，不影响主 Scene 管理）。
///
/// 三件事：
/// 1. 启动时创建全局悬浮窗的「锚定 Scene」（仅 TrollStore 环境有意义）；
/// 2. 锚定 Scene 的会话交给 EmptySceneDelegate——**绝不在 Scene 里建窗口**。
///    原项目（nongshifu/SysView）的关键架构：浮动 Scene 只是一个空锚，把自己撑成
///    系统级全屏前台存在；真正显示的悬浮窗口建在 App 进程的「无 Scene 空间」里。
///    若把窗口建进 Scene，Scene 内窗口空白处的触摸不会跨 Scene 下传，整屏卡死。
/// 3. Scene 就绪回调里让 FloatingBallController 建无 Scene 的独立悬浮窗。
final class RetroAppDelegate: NSObject, UIApplicationDelegate {
    /// 与 OverlayBridge 里的 kOverlaySceneIdentifier 保持一致
    static let overlaySceneIdentifier = "retrooverlay"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 全能签变体没有 platform-application 权限，全局悬浮窗不可用，不启动。
        // 另外全局 Scene 方案在部分机型/iOS 会冻结设备（拦截实体 Home 键），
        // 由 RetroEnv.globalOverlayEnabled 总开关控制，默认关闭 → 不创建私有 Scene。
        if RetroEnv.backgroundOverlayAvailable, RetroEnv.globalOverlayEnabled {
            OverlayBridge.setShellReadyHandler {
                DispatchQueue.main.async {
                    FloatingBallController.shared.overlayShellReady()
                }
            }
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
