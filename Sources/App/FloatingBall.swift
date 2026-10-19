import SwiftUI
import UIKit

/// 悬浮球：圆形，可拖动，自动吸附左右边缘，点击即保存最近 N 秒。
///
/// 它就是需求里"圆形悬浮窗 + 回溯两个字"的实现。
///
/// 两种窗口形态：
/// 1. 全局悬浮窗（TrollStore）：App 通过 FrontBoard 私有 API 创建「空锚浮动 Scene」
///    （Scene 内零窗口！），撑起 App 的系统级前台存在；真正的悬浮窗口是收到
///    shellReady 回调后、且用户点了「开始录屏」才创建的「不挂 windowScene 的独立
///    UIWindow」——而且它只有 68×68 一颗球这么大，绝不铺满全屏。
///    切到别的 App、回桌面、锁屏，球依然在，可点击、可拖动。
///    ⚠️ 关键教训（v1.3.0 真机三连卡死）：悬浮窗绝不能铺满全屏再用 hitTest 穿透！
///       整屏透明 windowLevel 10000 的窗口在你的设备/系统上会吃掉包括回桌面手势
///       在内的所有触摸，整屏卡死。只能做一颗球大小的小窗，物理上不挡其他区域。
/// 2. App 内窗口（普通签名 / 全能签 / 锚定 Scene 未就绪时）：只能在 App 前台显示，
///    切到别的 App 就消失（iOS 沙盒限制）。

@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()
    private init() {}

    private let ballSize: CGFloat = 68

    /// 全局悬浮窗（形态 1）：只有球大小的独立 UIWindow（不挂 windowScene）
    private var overlayWindow: PassthroughWindow?
    private var overlayBallHost: UIHostingController<BallOnlyView>?
    /// App 内窗口（形态 2）：同样只有球大小，挂在 App 的 windowScene 上
    private var inAppWindow: PassthroughWindow?
    private var inAppBallHost: UIHostingController<BallOnlyView>?

    private var shellReady = false
    private var pendingShow = false
    private var enabled = false

    /// 点击 / 长按回调，由 ContentView 注入
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    var isVisible: Bool {
        !(overlayBallHost?.view.isHidden ?? true) || !(inAppBallHost?.view.isHidden ?? true)
    }

    /// 全局悬浮窗是否就绪（浮动 Scene 已连上、独立窗口已建好）
    var overlayReady: Bool { overlayWindow != nil }

    /// 后台悬浮球开关（设置页可改，默认**关**）。开 = 走私有 FrontBoard 全局 Scene（跨 App/桌面）；
    /// 关 = 回退 App 内小窗（不冻结）。
    /// 全能签变体没有 platform-application 权限，恒返回 false。
    /// 由 RetroEnv.globalOverlayEnabled 控制「能力是否编译进 App」；本开关控制「是否启用」。
    static var overlayInBackground: Bool {
        guard RetroEnv.backgroundOverlayAvailable, RetroEnv.globalOverlayEnabled else { return false }
        // 未设置时默认 false（安全，不建私有 Scene），必须由用户主动打开开关才启用
        return UserDefaults.standard.bool(forKey: "retro.bg.overlay")
    }

    // MARK: - 球的位置（屏幕坐标，左上角，持久化）

    private func defaultPosition() -> CGPoint {
        let s = UIScreen.main.bounds.size
        // 默认放到左上角，避开中间「开始录制」等控件；用户可随意拖动
        return CGPoint(x: 20, y: 120)
    }

    private func currentPosition() -> CGPoint {
        let def = defaultPosition()
        let x = storedX >= 0 ? min(storedX, UIScreen.main.bounds.width - ballSize - 8) : def.x
        let y = storedY >= 0 ? min(max(storedY, 56), UIScreen.main.bounds.height - ballSize - 40) : def.y
        return CGPoint(x: x, y: y)
    }

    private var storedX: Double { UserDefaults.standard.double(forKey: "retro.ball.x") }
    private var storedY: Double { UserDefaults.standard.double(forKey: "retro.ball.y") }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let b = UIScreen.main.bounds
        // 底部留 40pt，避开 Home 指示条的上滑手势区
        let x = min(max(8, p.x), b.width - ballSize - 8)
        let y = min(max(56, p.y), b.height - ballSize - 40)
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

        // 后台悬浮开着：球用独立小窗（仅 68×68），不在全屏铺窗
        if Self.overlayInBackground {
            KeepAlive.shared.start()
            if shellReady {
                showOverlayNow()
            } else {
                pendingShow = true   // 等空锚 Scene 就绪回调
            }
            return
        }

        // 后台悬浮关着：走 App 内小窗
        KeepAlive.shared.stop()
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
        overlayWindow?.isHidden = true
        KeepAlive.shared.stop()
    }

    /// 场景激活后补挂（冷启动 / 从后台回前台时 windowScene 才就绪）
    func retryIfNeeded() {
        guard pendingShow, enabled else { return }
        pendingShow = false
        if let onTap, let onLongPress {
            show(onTap: onTap, onLongPress: onLongPress)
        }
    }

    // MARK: - 全局悬浮窗生命周期（RetroAppDelegate 通过 OverlayBridge 回调）

    /// 锚定 Scene 就绪（FBSystemShellInitialize 完成、浮动 Scene 已建好）。
    ///
    /// 此刻只标记就绪——真正的悬浮窗要等用户点「开始录屏」(show) 才创建，
    /// 而且窗口只有球那么大，绝不在 App 一启动就铺全屏挡住屏幕。
    func overlayShellReady() {
        shellReady = true
        if enabled, Self.overlayInBackground, pendingShow {
            pendingShow = false
            showOverlayNow()
        }
    }

    /// 创建「不挂 windowScene 的独立小窗」（仅球大小），挂上球。
    private func showOverlayNow() {
        guard let window = ensureOverlayWindow() else { return }
        ensureOverlayBall(in: window)
        window.isHidden = false
        overlayBallHost?.view.isHidden = false
        // 同时藏掉 App 内小窗，避免重复
        inAppWindow?.isHidden = true
        inAppBallHost?.view.isHidden = true
    }

    private func ensureOverlayWindow() -> PassthroughWindow? {
        if let w = overlayWindow { return w }
        let origin = currentPosition()
        // 关键：窗口只有球这么大，物理上只占屏幕一小块，不可能挡住其他区域
        let w = PassthroughWindow(frame: CGRect(origin: origin,
                                                size: CGSize(width: ballSize, height: ballSize)))
        w.windowLevel = UIWindow.Level(rawValue: 10000)
        w.backgroundColor = .clear
        w.isOpaque = false
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        w.rootViewController = vc
        w.isHidden = true
        overlayWindow = w
        // 交给桥接层：设备旋转时用 _rotateWindowToOrientation 同步转窗口
        OverlayBridge.attachOverlayWindow(w)
        return w
    }

    // MARK: - 建窗与建球

    private func makeBallHost(at position: CGPoint) -> UIHostingController<BallOnlyView> {
        let hc = UIHostingController(rootView: BallOnlyView(
            onTap: { [weak self] in self?.onTap?() },
            onLongPress: { [weak self] in self?.onLongPress?() },
            onDragChanged: { [weak self] t in self?.dragChanged(translation: t) },
            onDragEnded: { [weak self] in self?.dragEnded() }
        ))
        hc.view.backgroundColor = .clear
        hc.view.isUserInteractionEnabled = true
        hc.view.frame = CGRect(origin: position,
                               size: CGSize(width: ballSize, height: ballSize))
        return hc
    }

    private func ensureOverlayBall(in window: PassthroughWindow) {
        guard overlayBallHost == nil, let vc = window.rootViewController else { return }
        // 窗口本身就是球大小，球子视图铺满窗口（原点 0,0）
        let hc = makeBallHost(at: .zero)
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
            // App 内窗口铺满屏幕，球子视图放在 currentPosition
            let hc = makeBallHost(at: currentPosition())
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
        // 全局小窗：直接移动窗口本体（球铺满窗口，不用动子视图）
        overlayWindow?.frame.origin = newP
        // App 内小窗：窗口铺满屏幕，移动球子视图
        inAppBallHost?.view.frame.origin = newP
    }

    private func dragEnded() {
        defer { dragStart = nil }
        let cur = overlayWindow?.frame.origin
            ?? inAppBallHost?.view.frame.origin
            ?? currentPosition()
        let b = UIScreen.main.bounds
        // 离哪边近吸哪边
        let snappedX = (cur.x <= b.width - ballSize - cur.x) ? 8 : (b.width - ballSize - 8)
        let snapped = clamp(CGPoint(x: snappedX, y: cur.y))
        overlayWindow?.frame.origin = snapped
        inAppBallHost?.view.frame.origin = snapped
        persist(snapped)
    }
}

/// 穿透窗口：空白区域放行触摸。
///
/// 悬浮窗现在只有球大小，窗口外本就没有任何东西可挡；这里是双保险——
/// 万一窗口比球略大，空白处点击也放行给下层。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

/// 只画一颗球（68×68），由控制器把它作为子视图挂到窗口上。
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
