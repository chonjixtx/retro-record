import SwiftUI

/// 启动公告弹窗。
///
/// 打开 App 时弹出（24 小时内勾选过「一天内不弹公告」则跳过）：
/// - 公告内容：公益版 balls 回溯功能 + 开卡卡网地址；
/// - 「已阅读」按钮必须等 5 秒倒计时结束才能点（强制阅读）；
/// - 旁边的勾选框打勾后，24 小时内打开软件不再弹。
struct AnnouncementView: View {
    /// 关闭回调（由 ContentView 传入，置 false 关掉弹窗）
    let onClose: () -> Void

    /// 「一天内不弹公告」勾选状态（仅当次弹窗内生效，点「已阅读」时才落盘）
    @State private var hideForToday = false
    /// 阅读倒计时（秒）。0 表示可以点「已阅读」
    @State private var countdown = 5
    @State private var timer: Timer?

    private let announceURL = "https://kw.ovim.cn/shop/iosballs"

    var body: some View {
        VStack(spacing: 16) {
            Label("公告", systemImage: "megaphone.fill")
                .font(.title3.bold())
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 12) {
                Text("公益版 balls 回溯功能")
                    .font(.headline)
                Text("balls 开卡认准卡网：")
                    .font(.subheadline)
                // 卡网地址：可点击直接打开
                Link(destination: URL(string: announceURL)!) {
                    Text(announceURL)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.blue)
                        .underline()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Toggle("一天内不弹公告", isOn: $hideForToday)
                .font(.subheadline)

            Button {
                guard countdown <= 0 else { return }
                if hideForToday {
                    // 24 小时内不再弹出
                    UserDefaults.standard.set(
                        Date().timeIntervalSince1970 + 24 * 3600,
                        forKey: "retro.announce.hideUntil"
                    )
                }
                onClose()
            } label: {
                Text(countdown > 0 ? "已阅读（\(countdown)s）" : "已阅读")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(countdown > 0)
        }
        .padding(20)
        .onAppear { startCountdown() }
        .onDisappear { timer?.invalidate() }
    }

    private func startCountdown() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            Task { @MainActor in
                countdown -= 1
                if countdown <= 0 {
                    countdown = 0
                    t.invalidate()
                }
            }
        }
    }
}
