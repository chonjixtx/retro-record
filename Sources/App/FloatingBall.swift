import SwiftUI
import UIKit

/// 悬浮球：圆形，可拖动，自动吸附左右边缘，点击即保存最近 N 秒。
///
/// 它就是需求里"圆形悬浮窗 + 回溯两个字"的实现。
///
/// 两种窗口形态：
/// 1. 全局悬浮窗（TrollStore）：App 通过 FrontBoard 私有 API 创建一个独立浮动 Scene，
///    它的窗口挂在系统最上层（层级 10000）。切到别的 App、回桌面、锁屏，球依然在，
///    可点击、可拖动。依赖 TrollStore 安装时保留的 platform-application 等 entitlements。
/// 2. App 内窗口（普通签名 / 全能签 / 浮动 Scene 未就绪时）：只能在 App 前台显示，
///    切到别的 App 就消失（iOS 沙盒限制）。
///
/// 关键设计：整屏窗口的根视图是一个「不收触摸」的普通 UIViewController，
/// 悬浮球只是挂上去的一颗 68×68 的可交互子视图。这样空白区域 hitTest 自然落到 nil，
/// 下层界面（含回桌面手势）照常接收，只有球本身拦截点击——绝不会整屏挡死。
@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()
    private init() {}

    private let ballSize: CGFloat = 68

    /// 全局悬浮窗（形态 1）：整屏透明窗口（不收触摸），球作为独立可交互子视图挂上去
    private var overlayWindow: PassthroughWindow?
    private var overlayBallHost: UIHostingController<BallOnlyView>?
    /// App 内窗口（形态 2）
    private var inAppWindow: PassthroughWindow?
    private var inAppBallHost: UIHostingController<BallOnlyView>?

    private var pendingShow = false
    private var enabled = false

    /// 点击 / 长按回调，由 ContentView 注入
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    var isVisible: Bool {
        !(overlayBallHost?.view.isHidden ?? true) || !(inAppBallHost?.view.isHidden ?? true)
    }

    /// 全局悬浮窗是否就绪（浮动 Scene 已连接并建好窗口）。
    var overlayReady: Bool { overlayWindow != nil }

    /// 后台悬浮球开关（设置页可改，默认开）。关掉即回到普通签名行为：只在 App 前台显示。
    /// 全能签变体没有 platform-application 权限，后台悬浮一律不可用，恒返回 false。
    static var overlayInBackground: Bool {
        guard RetroEnv.backgroundOverlayAvailable else { return false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "retro.bg.overlay") == nil { return true }
        return defaults.bool(forKey: "retro.bg.overlay")
    }

    // MARK: - 球的位置（屏幕坐标，左上角，持久化）

    private func defaultPosition() -> CGPoint {
        let s = UIScreen.main.bounds.size
        return CGPoint(x: s.width - ballSize - 12, y: s.height * 0.58)
    }

    private func currentPosition() -> CGPoint {
        let def = defaultPosition()
        let x = storedX >= 0 ? min(storedX, UIScreen.main.bounds.width - ballSize - 8) : def.x
        let y = storedY >= 0 ? min(max(storedY, 56), UIScreen.main.bounds.height - ballSize - 24) : def.y
        return CGPoint(x: x, y: y)
    }

    private var storedX: Double { UserDefaults.standard.double(forKey: "retro.ball.x") }
    private var storedY: Double { UserDefaults.standard.double(forKey: "retro.ball.y") }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let b = UIScreen.main.bounds
        let x = min(max(8, p.x), b.width - ballSize - 8)
        let y = min(max(56, p.y), b.height - ballSize - 24)
        return CGPoint(x: x, y: y)
    }

    private func persist(_ p: CGPoint) {
        UserDefaults.standard.set(Double(p.x), forKey: "retro.ball.x")
        UserDefaults.standard.set(Double(p.y), forKey: "retro.ball.y")
    }

    // MARK: - 显隐

    func show(onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.onTap = onTap
        self.onLongPress = onLongPress
        enabled = true

        if Self.overlayInBackground { KeepAlive.shared.start() } else { KeepAlive.shared.stop() }

        // 后台悬浮开着 + 全局窗口就绪：只显示它（本来就盖在 App 界面之上），不再建 App 内窗口
        if Self.overlayInBackground, let window = overlayWindow {
            ensureOverlayBall(in: window)
            overlayWindow?.isHidden = false
            overlayBallHost?.view.isHidden = false
            inAppWindow?.isHidden = true
            inAppBallHost?.view.isHidden = true
            return
        }
        // 后台悬浮关着：确保全局窗口不挡在前台，走 App 内窗口
        overlayWindow?.isHidden = true
        overlayBallHost?.view.isHidden = true
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            pendingShow = true
            return
        }
        ensureInAppBall(in: scene)
        inAppWindow?.isHidden = false
        inAppBallHost?.view.isHidden = false
        pendingShow = false
    }

    func hide() {
        enabled = false
        overlayBallHost?.view.isHidden = true
        inAppBallHost?.view.isHidden = true
        inAppWindow?.isHidden = true
        KeepAlive.shared.stop()
    }

    /// 场景激活后补挂（冷启动 / 从后台回前台时 windowScene 才就绪）
    func retryIfNeeded() {
        guard pendingShow, enabled, overlayWindow == nil else { return }
        pendingShow = false
        if let onTap, let onLongPress {
            show(onTap: onTap, onLongPress: onLongPress)
        }
    }

    // MARK: - 全局悬浮窗生命周期（OverlaySceneDelegate 调用）

    /// 浮动 Scene 连上了，窗口已建好（默认隐藏）
    func overlaySceneConnected(_ window: PassthroughWindow) {
        overlayWindow = window
        // 根视图设为不收触摸；球稍后作为可交互子视图挂上去（见 PassthroughWindow 注释）
        if let vc = window.rootViewController {
            vc.view.backgroundColor = .clear
            vc.view.isUserInteractionEnabled = true
        }
        if enabled, Self.overlayInBackground {
            ensureOverlayBall(in: window)
            overlayWindow?.isHidden = false
            overlayBallHost?.view.isHidden = false
        }
    }

    /// 浮动 Scene 断开（极少见）：回退到 App 内窗口
    func overlaySceneDisconnected() {
        overlayWindow = nil
        overlayBallHost = nil
        if enabled, let onTap, let onLongPress {
            show(onTap: onTap, onLongPress: onLongPress)
        }
    }

    // MARK: - 建窗与建球

    private func makeBallHost() -> UIHostingController<BallOnlyView> {
        let hc = UIHostingController(rootView: BallOnlyView(
            onTap: { [weak self] in self?.onTap?() },
            onLongPress: { [weak self] in self?.onLongPress?() },
            onDragChanged: { [weak self] t in self?.dragChanged(translation: t) },
            onDragEnded: { [weak self] in self?.dragEnded() }
        ))
        hc.view.backgroundColor = .clear
        hc.view.isUserInteractionEnabled = true
        hc.view.frame = CGRect(origin: currentPosition(),
                               size: CGSize(width: ballSize, height: ballSize))
        return hc
    }

    private func ensureOverlayBall(in window: PassthroughWindow) {
        guard overlayBallHost == nil, let vc = window.rootViewController else { return }
        let hc = makeBallHost()
        vc.addChild(hc)
        vc.view.addSubview(hc.view)
        hc.didMove(toParent: vc)
        overlayBallHost = hc
    }

    private func ensureInAppBall(in scene: UIWindowScene) {
        if inAppWindow == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .statusBar + 1
            w.backgroundColor = .clear
            w.isOpaque = false
            let vc = UIViewController()
            vc.view.backgroundColor = .clear
            w.rootViewController = vc
            w.isHidden = false
            inAppWindow = w
        }
        guard let w = inAppWindow, let vc = w.rootViewController else { return }
        if inAppBallHost == nil {
            let hc = makeBallHost()
            vc.addChild(hc)
            vc.view.addSubview(hc.view)
            hc.didMove(toParent: vc)
            inAppBallHost = hc
        }
    }

    // MARK: - 拖拽

    private var dragStart: CGPoint?

    private func dragChanged(translation: CGSize) {
        if dragStart == nil { dragStart = currentPosition() }
        let base = dragStart!
        let newP = clamp(CGPoint(x: base.x + translation.width, y: base.y + translation.height))
        overlayBallHost?.view.frame.origin = newP
        inAppBallHost?.view.frame.origin = newP
    }

    private func dragEnded() {
        defer { dragStart = nil }
        guard let cur = overlayBallHost?.view.frame.origin ?? inAppBallHost?.view.frame.origin else { return }
        let b = UIScreen.main.bounds
        // 离哪边近吸哪边
        let snappedX = (cur.x <= b.width - ballSize - cur.x) ? 8 : (b.width - ballSize - 8)
        let snapped = clamp(CGPoint(x: snappedX, y: cur.y))
        overlayBallHost?.view.frame.origin = snapped
        inAppBallHost?.view.frame.origin = snapped
        persist(snapped)
    }
}

/// 穿透窗口：整屏不收触摸，只有作为子视图挂上去的「球」是可交互的。
///
/// 因为根视图是普通 UIViewController.view，super.hitTest 在空白区域命中根视图本身，
/// 这里把它转成 nil 放行给下层；命中球子视图则正常返回。这样不会挡住 App 内按钮，
/// 也不会拦住系统回桌面手势。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

/// 只画一颗球（68×68），由控制器把它作为独立可交互子视图挂到窗口上。
struct BallOnlyView: View {
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    private let ballSize: CGFloat = 68

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.82))
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            VStack(spacing: 1) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("回溯")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
        .frame(width: ballSize, height: ballSize)
        .contentShape(Circle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.6, perform: onLongPress)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { onDragChanged($0.translation) }
            .onEnded { _ in onDragEnded() })
    }
}
