import Foundation
import UserNotifications

/// 通知栏一键保存。
///
/// 录制时发一条常驻本地通知，带「保存最近片段」动作按钮。用户在任意界面——
/// 别的 App 里、桌面上、甚至锁屏——下拉通知中心点一下就能保存，不用切回 App，
/// 也完全不依赖私有 FrontBoard Scene，因此**不会冻结、不会闪退**。
///
/// 动作不带 .foreground option：点击时 App 在后台处理，不会把录制画面顶掉。
enum SaveNotification {
    static let categoryID = "RETRO_SAVE"
    static let actionID = "RETRO_SAVE_ACTION"
    static let requestID = "retro.save.ongoing"

    /// 注册通知分类（带「保存」按钮）
    static func registerCategory() {
        let action = UNNotificationAction(identifier: actionID,
                                          title: "保存最近片段",
                                          options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [action],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 开始录制 → 发常驻通知
    static func post(retentionSeconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "回溯录制中"
        // iOS 的通知按钮默认折叠：必须「长按通知」才会显示动作按钮，文案里写明
        content.body = "在通知中心【长按】这条通知 → 点「保存最近片段」，即可保存最近 \(retentionSeconds) 秒（轻点会打开 App）"
        content.categoryIdentifier = categoryID
        content.sound = nil
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 停止录制 → 撤掉通知
    static func cancel() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
    }
}

/// 通知动作 → 触发保存的桥接。
/// AppDelegate（UNUserNotificationCenterDelegate）在用户点通知按钮时调用 `fire()`；
/// ContentView 在 onAppear 时把 `onSave` 注入成 `model.saveRetro()`。
final class SaveTrigger {
    static let shared = SaveTrigger()
    private init() {}

    /// ContentView 注入。若点通知时 App 是冷启动、回调还没注入，先把请求挂起，
    /// 等 onSave 注入后立刻补执行一次。
    var onSave: (() -> Void)? {
        didSet {
            if pending {
                pending = false
                onSave?()
            }
        }
    }
    private var pending = false

    func fire() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let save = self.onSave {
                save()
            } else {
                self.pending = true
            }
        }
    }
}
