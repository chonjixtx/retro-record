import SwiftUI
import UIKit

/// 全局悬浮 Scene 的代理。
///
/// 浮动 Scene 由 OverlayBridge 通过 FrontBoard 私有 API 创建，连接时UIKit 会走到这里。
/// 我们在这个 Scene 里放一颗压在全系统最上层的窗口，里面就是「回溯」悬浮球——
/// App 退到后台、回到桌面、锁屏，球都还在，点一下即可在后台保存。
///
/// 权限前提：TrollStore 安装 + 二进制保留 platform-application 等 entitlements。
/// 普通签名（含全能签）下 Scene 根本建不起来，这个类不会被实例化，
/// 悬浮球自动降级为「仅 App 内显示」。
@MainActor
final class OverlaySceneDelegate: UIResponder, UISceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            FloatingBallController.shared.overlaySceneDisconnected()
            return
        }

        let window = PassthroughWindow(windowScene: windowScene)
        // 层级拉到 10000，压在状态栏、系统弹窗之上
        window.windowLevel = UIWindow.Level(rawValue: 10000)
        window.backgroundColor = .clear
        window.isOpaque = false

        let ball = FloatingBallView(
            onTap: { FloatingBallController.shared.onTap?() },
            onLongPress: { FloatingBallController.shared.onLongPress?() }
        )
        let hosting = UIHostingController(rootView: ball)
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        // 先藏起来，等 FloatingBallController.show() 再放出来
        window.isHidden = true
        self.window = window

        OverlayBridge.attachOverlayWindow(window)
        FloatingBallController.shared.overlaySceneConnected(window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        OverlayBridge.attachOverlayWindow(nil)
        FloatingBallController.shared.overlaySceneDisconnected()
        window = nil
    }
}

/// 兜底：未知来源的 Scene 会话连进来时，给一个空场景，不渲染任何内容，
/// 避免 SwiftUI 把主界面塞进一个来路不明的窗口里。
@MainActor
final class EmptySceneDelegate: UIResponder, UISceneDelegate {
    var window: UIWindow?
}
