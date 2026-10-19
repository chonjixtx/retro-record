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
/// 全局悬浮靠 KeepAlive 的后台音频保活，防止 App 切后台后被系统挂起。
@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()
    private init() {}

    /// App 内窗口（形态 2）
    private var inAppWindow: PassthroughWindow?
    /// 全局悬浮窗口（形态 1），由 OverlaySceneDelegate 建好後交过来
    private var overlayWindow: PassthroughWindow?
    /// 场景还没就绪时先记着，等场景激活再补挂
    private var pendingShow = false
    /// 当前是否处于「显示悬浮球」状态
    private var enabled = false

    /// 点击 / 长按回调，由 ContentView 注入；全局窗口早于 ContentView 建好，
    /// 所以球里存的是「取最新回调」的闭包
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    var isVisible: Bool {
        (overlayWindow?.isHidden == false) || (inAppWindow?.isHidden == false)
    }

    /// 全局悬浮窗是否就绪（浮动 Scene 已连接并建好窗口）。
    /// false = 当前装的是普通签名包，球只会在 App 内显示。
    var overlayReady: Bool { overlayWindow != nil }

    /// 后台悬浮球开关（设置页可改，默认开）。关掉即回到普通签名行为：只在 App 前台显示。
    /// 全能签变体没有 platform-application 权限，后台悬浮一律不可用，恒返回 false，
    /// 连后台音频保活都不会启动。
    static var overlayInBackground: Bool {
        guard RetroEnv.backgroundOverlayAvailable else { return false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "retro.bg.overlay") == nil { return true }
        return defaults.bool(forKey: "retro.bg.overlay")
    }

    func show(onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.onTap = onTap
        self.onLongPress = onLongPress
        enabled = true

        // 后台悬浮开着就保活；关了立刻停，不留后台音频
        if Self.overlayInBackground { KeepAlive.shared.start() } else { KeepAlive.shared.stop() }

        // 后台悬浮开着 + 全局窗口就绪：只显示它（它本来就盖在 App 界面之上），不再建 App 内窗口
        if Self.overlayInBackground, let overlay = overlayWindow {
            overlay.isHidden = false
            inAppWindow?.isHidden = true
            inAppWindow = nil
            return
        }
        // 后台悬浮关着：确保全局窗口不挡在前台，走 App 内窗口
        overlayWindow?.isHidden = true
        // 已有 App 内窗口：直接放出来
        if let existing = inAppWindow {
            existing.isHidden = false
            return
        }
        // 建 App 内窗口
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            pendingShow = true
            return
        }
        inAppWindow = makeBallWindow(scene: scene)
        pendingShow = false
    }

    func hide() {
        enabled = false
        overlayWindow?.isHidden = true
        inAppWindow?.isHidden = true
        inAppWindow = nil
        KeepAlive.shared.stop()
    }

    /// 场景激活后补挂（App 冷启动 / 从后台回前台时 windowScene 才就绪）
    func retryIfNeeded() {
        guard pendingShow, enabled, overlayWindow == nil, inAppWindow == nil else { return }
        pendingShow = false
        if let onTap, let onLongPress {
            show(onTap: onTap, onLongPress: onLongPress)
        }
    }

    // MARK: - 全局悬浮窗生命周期（OverlaySceneDelegate 调用）

    /// 浮动 Scene 连上了，窗口已建好（默认隐藏）
    func overlaySceneConnected(_ window: PassthroughWindow) {
        overlayWindow = window
        // 只有「后台悬浮球」开关也开着时才立刻显示，否则等用户在设置里打开
        if enabled && Self.overlayInBackground { window.isHidden = false }
    }

    /// 浮动 Scene 断开（极少见）：回退到 App 内窗口
    func overlaySceneDisconnected() {
        overlayWindow = nil
        if enabled, let onTap, let onLongPress {
            show(onTap: onTap, onLongPress: onLongPress)
        }
    }

    // MARK: - 建窗

    private func makeBallWindow(scene: UIWindowScene) -> PassthroughWindow {
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isOpaque = false
        let hosting = UIHostingController(rootView: FloatingBallView(
            onTap: { [weak self] in self?.onTap?() },
            onLongPress: { [weak self] in self?.onLongPress?() }
        ))
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        window.isHidden = false
        return window
    }
}

/// 穿透窗口：点到球的空白区域就放行给下面的界面，只有球本身吃掉点击
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

struct FloatingBallView: View {
    private let ballSize: CGFloat = 68

    @State private var position: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var isDragging = false
    @AppStorage("retro.ball.x") private var storedX: Double = -1
    @AppStorage("retro.ball.y") private var storedY: Double = -1

    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ballView
                    .frame(width: ballSize, height: ballSize)
                    .offset(x: currentPosition(in: size).x, y: currentPosition(in: size).y)
                    .gesture(dragGesture(in: size))
                    .onTapGesture(perform: onTap)
                    .onLongPressGesture(minimumDuration: 0.6, perform: onLongPress)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
            }
            .onAppear { restore(in: size) }
        }
        .ignoresSafeArea()
    }

    private var ballView: some View {
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
        .scaleEffect(isDragging ? 1.08 : 1.0)
    }

    private func currentPosition(in size: CGSize) -> CGPoint {
        // 横竖屏切换后窗口尺寸变了，旧坐标可能跑出屏幕，这里每次都夹回可视区域
        let base = position ?? Self.defaultPosition(in: size, ballSize: ballSize)
        let maxX = max(8, size.width - ballSize - 8)
        let maxY = max(56, size.height - ballSize - 24)
        return CGPoint(
            x: min(max(8, base.x), maxX),
            y: min(max(56, base.y), maxY)
        )
    }

    private static func defaultPosition(in size: CGSize, ballSize: CGFloat) -> CGPoint {
        CGPoint(x: size.width - ballSize - 12, y: size.height * 0.58)
    }

    private func restore(in size: CGSize) {
        guard position == nil else { return }
        if storedX >= 0, storedY >= 0 {
            position = CGPoint(
                x: min(storedX, size.width - ballSize - 8),
                y: min(storedY, size.height - ballSize - 24)
            )
        } else {
            position = Self.defaultPosition(in: size, ballSize: ballSize)
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStart == nil { dragStart = currentPosition(in: size) }
                let base = dragStart ?? currentPosition(in: size)
                var x = base.x + value.translation.width
                var y = base.y + value.translation.height
                x = min(max(8, x), size.width - ballSize - 8)
                y = min(max(56, y), size.height - ballSize - 24)
                position = CGPoint(x: x, y: y)
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
                dragStart = nil
                let left = currentPosition(in: size).x
                let right = size.width - ballSize - currentPosition(in: size).x
                let snappedX = left <= right ? 8 : size.width - ballSize - 8
                position = CGPoint(x: snappedX, y: currentPosition(in: size).y)
                storedX = Double(position?.x ?? -1)
                storedY = Double(position?.y ?? -1)
            }
    }
}
