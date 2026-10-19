import SwiftUI
import UIKit

/// 兜底：锚定 Scene（retrooverlay）与未知来源的 Scene 会话连进来时，**不建任何窗口**。
///
/// 架构关键（照抄原项目 nongshifu/SysView 的做法）：
/// 浮动 Scene 只是一个「空锚」——它把自己撑成系统级全屏前台存在，让 App 的窗口
/// 在回桌面/锁屏后依然被系统展示；但它自己内部零窗口、零内容。
///
/// 绝不能在这个 Scene 里装悬浮窗：Scene 是独立的展示上下文，它内部窗口空白区域的
/// 触摸不会跨 Scene 下传给桌面/其他 App，会造成整屏卡死（v1.3.0 首版的教训）。
/// 悬浮窗口由 FloatingBallController 在收到 shellReady 回调后，以「不挂 windowScene
/// 的独立 UIWindow」方式创建（见 FloatingBall.swift）。
@MainActor
final class EmptySceneDelegate: UIResponder, UISceneDelegate {
    var window: UIWindow?
}
