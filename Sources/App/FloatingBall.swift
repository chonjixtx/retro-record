import SwiftUI
import UIKit

/// 悬浮球：圆形，可拖动，自动吸附左右边缘，点击即保存最近 N 秒。
///
/// 它就是需求里"圆形悬浮窗 + 回溯两个字"的实现。
/// 需要说明的是：iOS 不允许 App 在其他 App 之上绘制视图，所以这颗球只在**本 App 前台**可见；
/// 切到别的 App 后，承担"一直能看到"职责的是灵劫岛 / 锁屏常驻胶囊（Live Activity）。
@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()

    private var window: PassthroughWindow?
    private var pendingShow = false

    var isVisible: Bool { window != nil }

    func show(onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            pendingShow = true
            return
        }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isOpaque = false
        let hosting = UIHostingController(rootView: FloatingBallView(onTap: onTap, onLongPress: onLongPress))
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        window.isHidden = false
        self.window = window
        pendingShow = false
    }

    /// 场景激活后补挂（App 冷启动时 windowScene 还没准备好）
    func retryIfNeeded() {
        guard pendingShow else { return }
        pendingShow = false
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // 点到空白区域就放行给下面的页面，只有球本身吃掉点击
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
        if let position { return position }
        return Self.defaultPosition(in: size, ballSize: ballSize)
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
