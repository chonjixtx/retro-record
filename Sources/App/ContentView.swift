import SwiftUI
import UIKit
import UserNotifications

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("retro.bg.overlay") private var backgroundOverlay: Bool = false
    @State private var notifStatus: String = ""
    @EnvironmentObject private var model: RecorderViewModel

    var body: some View {
        // NavigationStack 是 iOS 16 专有，这里用 iOS 13 起就有的 NavigationView 兼容旧系统
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    actionCard
                    startCard
                    diagnosisCard
                    settingsCard
                    savedCard
                    notesCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("回溯")
            .navigationBarTitleDisplayMode(.large)
        }
        // iPad 上 NavigationView 默认走分栏（DoubleColumn），界面会被挤到侧栏里
        .navigationViewStyle(.stack)
        .sheet(isPresented: shareBinding) {
            if let url = model.showingShareURL {
                ShareSheet(url: url)
            }
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onChange(of: model.floatingBallEnabled) { enabled in
            syncFloatingBall(enabled: enabled)
        }
        .onAppear {
            syncFloatingBall(enabled: model.floatingBallEnabled)
            // 扩展进程没有 UI，弹不了权限框，只能由主 App 代请求
            model.requestPhotoAuth()

            // 通知栏一键保存：把动作回调接到 saveRetro
            let vm = model
            SaveTrigger.shared.onSave = { [weak vm] in
                guard let vm else { return }
                vm.saveRetro()
                // iOS 在通知被点击后会自动移除它 → 2 秒后补发一条，通知常驻可反复保存
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak vm] in
                    guard let vm else { return }
                    SaveNotification.post(retentionSeconds: Int(vm.retentionSeconds), delay: 1)
                }
                // 从通知栏触发时 App 在后台，导出需要额外运行时间，申请一段后台宽限
                var bgTask = UIApplication.shared.beginBackgroundTask(withName: "retro-notif-save")
                DispatchQueue.main.asyncAfter(deadline: .now() + 28) {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
            }
            SaveNotification.registerCategory()
            SaveNotification.requestAuthorization()
            SaveNotification.statusText { notifStatus = $0 }
            // 录制已在跑就直接挂上常驻通知（例如从后台被重新唤起）
            if model.systemCapturing {
                SaveNotification.post(retentionSeconds: Int(model.retentionSeconds))
            }
            // 通知权限被拒绝过 → 明确提示，否则录制时通知中心什么都看不到
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                if settings.authorizationStatus == .denied {
                    DispatchQueue.main.async {
                        vm.notice = Notice(
                            text: "通知权限被拒绝，通知栏保存用不了。\n请到 iPad「设置 → 通知 → 回溯」打开「允许通知」，再重新开始录制。",
                            isError: true
                        )
                    }
                }
            }

            // 上次打开「后台悬浮球」后异常退出（冻结/闪退）→ 明确提示并引导改用通知保存
            if UserDefaults.standard.bool(forKey: "retro.bg.overlay.wasOn") {
                UserDefaults.standard.set(false, forKey: "retro.bg.overlay.wasOn")
                model.notice = Notice(
                    text: "上次打开「后台悬浮球」后 App 异常退出——该私有方案在你的设备（iPad Pro 11\" 二代 / iOS 15.4.1）上会冻结或闪退，已自动关闭。请改用通知栏保存：录制时下拉通知中心，点「保存最近片段」即可。",
                    isError: true
                )
            }
        }
        .onChange(of: model.exportQuality) { _ in model.persist() }
        .onChange(of: model.systemCapturing) { capturing in
            // 录屏一开始挂上常驻通知；停止要延时确认再撤，避免 isCaptured 闪 false 误删
            model.handleCaptureChanged(capturing)
        }
        .onOpenURL { url in
            if url.host == "save" || url.absoluteString.contains("save") {
                model.refresh()
                model.saveRetro()
            }
        }
        .alert(item: Binding(
            get: { model.notice },
            set: { model.notice = $0 }
        )) { notice in
            Alert(
                title: Text(notice.isError ? "出错了" : "完成"),
                message: Text(notice.text),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 卡片

    /// 降级模式下主 App 读不到扩展的心跳文件，只能靠系统录制状态判断
    private var headlineText: String {
        if model.isRecording { return "录制中 · 环形缓冲持续滚动" }
        if model.systemCapturing { return "系统录屏进行中 · 正在缓冲" }
        if model.wasInterrupted { return "录制被中断（多半是锁屏了）" }
        return "未在录制"
    }

    private var statusCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill((model.isRecording || model.systemCapturing) ? Color.red : Color(uiColor: .tertiaryLabel))
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(headlineText)
                        .font(.headline)
                    Text(AppGroup.isShared
                         ? "已缓存 \(model.cachedDurationText) · 占用 \(model.cachedSizeText)"
                         : model.degradedCacheText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 存储模式说明：共享模式灰色，降级模式橙色提示
                    Text(AppGroup.diagnosisText)
                        .font(.caption)
                        .foregroundColor(AppGroup.isShared ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    // 这一行不依赖任何跨进程通信，是"到底在不在录"最可靠的判据
                    HStack(spacing: 6) {
                        Image(systemName: model.systemCapturing ? "record.circle.fill" : "record.circle")
                            .foregroundColor(model.systemCapturing ? .red : .secondary)
                        Text(model.captureText)
                            .font(.caption)
                            .foregroundColor(model.systemCapturing ? .red : .secondary)
                    }
                    if model.wasInterrupted {
                        Button("知道了，重新起录") {
                            model.markInterruptedHandled()
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var actionCard: some View {
        Card {
            VStack(spacing: 10) {
                Button {
                    model.saveRetro()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("保存最近 \(Int(model.retentionSeconds)) 秒")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(model.isExporting ? Color.gray : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // 降级模式下主 App 读不到分片，缓存秒数恒为 0，此时不能据此禁用按钮
                .disabled(model.isExporting || (AppGroup.isShared && model.cachedSeconds < 1))

                if let progress = model.exportProgress {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var startCard: some View {
        Card {
            VStack(spacing: 12) {
                BroadcastStarter(
                    title: model.wasInterrupted ? "重新起录" : "开始录制",
                    systemImage: "record.circle",
                    background: .systemRed
                ) {
                    model.willStartRecording()
                }
                .frame(width: 260, height: 52)

                Text("点一下会弹出 iOS 系统选择器，选中「回溯录制」→ 开始录制。这一步必须由你本人点击，任何 App 都绕不过去。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("如何停止录制") {
                    model.stopRecordingReminder()
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var diagnosisCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("诊断", systemImage: "stethoscope")
                    .font(.headline)

                Text(AppGroup.diagnosisText)
                    .font(.caption)
                    .foregroundColor(AppGroup.isShared ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)

                // 明确告诉用户装的是哪个变体，避免"我明明要全能签版怎么还有后台悬浮球开关"这类困惑
                Text("构建变体：\(RetroEnv.variantLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("主 App \(model.photoAuthText)")
                    .font(.caption)
                    .foregroundColor(model.photoAuthStatus == .authorized ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("请求相册权限") { model.requestPhotoAuth() }
                        .font(.footnote)
                        .buttonStyle(.borderedProminent)
                    Button("检测扩展") { model.probeExtension() }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                    Button("打开系统设置") { model.openSystemSettings() }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button("发测试通知(5秒后)") {
                        SaveNotification.registerCategory()
                        SaveNotification.post(retentionSeconds: Int(model.retentionSeconds), delay: 5)
                        SaveNotification.statusText { notifStatus = $0 }
                        model.notice = Notice(text: "5 秒后发一条测试通知。\n现在立刻按 Home 回桌面（或切到别的 App），等 6 秒再下拉通知中心，长按「回溯录制中」。\n关键：通知不会出现在 App 前台的通知中心里，必须离开 App 才看得到。", isError: false)
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    Button("请求通知权限") {
                        SaveNotification.requestAuthorization()
                        SaveNotification.statusText { notifStatus = $0 }
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }

                if !notifStatus.isEmpty {
                    Text(notifStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(model.extensionAliveText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 全局悬浮窗状态：就绪 = 巨魔商店安装且权限保留，退到桌面球依然在
                if RetroEnv.backgroundOverlayAvailable && RetroEnv.globalOverlayEnabled {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: FloatingBallController.shared.overlayReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(FloatingBallController.shared.overlayReady ? .green : .orange)
                        Text(FloatingBallController.shared.overlayReady
                             ? "后台悬浮球：全局浮动窗口已就绪，退到桌面/锁屏球依然显示可点"
                             : "后台悬浮球：浮动窗口未就绪（需巨魔商店安装并保留 platform-application 权限），当前仅 App 内显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let last = model.lastExtensionLine {
                    Text("扩展最近一条：" + last)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !model.extensionLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.extensionLogs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button("清空日志") { model.clearLogs() }
                        .font(.footnote)
                }
            }
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("录制设置", systemImage: "slider.horizontal.3")
                    .font(.headline)

                HStack {
                    Text("保留时长")
                    Spacer()
                    TextField("600", text: retentionBinding)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([60, 300, 600, 1800], id: \.self) { value in
                            Chip(title: "\(value) 秒", selected: Int(model.retentionSeconds) == value) {
                                model.retentionSeconds = Double(value)
                            }
                        }
                    }
                }

                Divider()

                Picker("导出画质", selection: $model.exportQuality) {
                    ForEach(ExportQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Picker("录制码率", selection: $model.bitrateMbps) {
                    Text("4 Mbps").tag(4.0)
                    Text("6 Mbps").tag(6.0)
                    Text("8 Mbps").tag(8.0)
                    Text("12 Mbps").tag(12.0)
                }
                .pickerStyle(.segmented)

                Toggle("录进麦克风声音", isOn: $model.microphoneEnabled)
                Toggle("App 内悬浮球", isOn: $model.floatingBallEnabled)

                // 全局悬浮球（私有 FrontBoard Scene 方案）。⚠️ 高风险：在部分机型/iOS
                // 会让私有前台 Scene 拦截「上滑回桌面」手势 → 整屏冻结，需硬重启脱困。
                // 因此做成手动开关、默认关闭：只有用户主动打开才建 Scene，开屏即安全。
                if RetroEnv.backgroundOverlayAvailable && RetroEnv.globalOverlayEnabled {
                    Toggle("后台悬浮球（实验·高风险）", isOn: $backgroundOverlay)
                        .onChange(of: backgroundOverlay) { on in
                            if on {
                                // 用户主动打开 → 建立全局浮动 Scene + 球
                                OverlayBridge.setShellReadyHandler {
                                    DispatchQueue.main.async {
                                        FloatingBallController.shared.overlayShellReady()
                                    }
                                }
                                OverlayBridge.startOverlayScene()
                            } else {
                                // 关闭 → 拆掉 Scene，球收起，避免冻结残留
                                OverlayBridge.teardown()
                                FloatingBallController.shared.hide()
                            }
                            // 让 FloatingBallController 按新开关决定走全局/App 内
                            syncFloatingBall(enabled: model.floatingBallEnabled)
                        }
                }

                Button(role: .destructive) {
                    model.clearCache()
                } label: {
                    Label("清空环形缓冲", systemImage: "trash")
                        .font(.subheadline)
                }
            }
        }
    }

    private var savedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("已保存", systemImage: "film")
                    .font(.headline)

                if model.savedFiles.isEmpty {
                    Text("还没有保存过视频。录制一段时间后点「保存最近 N 秒」，或点悬浮球。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.savedFiles, id: \.self) { url in
                        HStack {
                            Image(systemName: "video")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.open(url)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("你必须知道的三件事", systemImage: "info.circle")
                    .font(.headline)
                NoteRow(text: "录制时状态栏会常驻系统录制指示器，这是 iOS 强制的，无法隐藏。")
                if !AppGroup.isShared {
                    NoteRow(text: "当前是降级模式：视频保存后出现在「照片」App，不会出现在下方「已保存」列表里。")
                    NoteRow(text: "保底办法：下拉控制中心点红色按钮停止录制，最近一段会自动存进相册。")
                }
                NoteRow(text: "锁屏、息屏、来电会中断录制。想一直录就别让设备锁屏。")
                // 主推：通知栏一键保存（不依赖私有 API，绝不冻结/闪退）
                NoteRow(text: "【推荐】录制时下拉通知中心，点「保存最近片段」即可在任意界面（别的 App、桌面、锁屏）一键保存最近 N 秒，不用切回 App，也不会冻结或闪退。若通知没出现：去「设置 → 通知 → 回溯」允许通知。")
                if RetroEnv.backgroundOverlayAvailable && RetroEnv.globalOverlayEnabled {
                    NoteRow(text: "「后台悬浮球（实验·高风险）」用私有 FrontBoard Scene，在你的机型（iPad Pro 11\" 二代 / iOS 15.4.1）上实测会整屏冻结或直接闪退，**不建议打开**。开关每次启动会自动复位为关，避免卡在异常状态。若误开导致冻结，强制重启：快速按一下音量+ → 快速按一下音量− → 长按顶部电源键约 10 秒。")
                }
                NoteRow(text: "持续录屏耗电明显，1080p / 6Mbps 下每 10 分钟约 450MB。")
            }
        }
    }

    // MARK: - 辅助

    private var shareBinding: Binding<Bool> {
        Binding(
            get: { model.showingShareURL != nil },
            set: { if !$0 { model.showingShareURL = nil } }
        )
    }

    private var retentionBinding: Binding<String> {
        Binding(
            get: { String(Int(model.retentionSeconds)) },
            set: { text in
                let digits = text.filter { $0.isNumber }
                guard let value = Double(digits), value >= 1 else { return }
                model.retentionSeconds = min(value, 7200)
            }
        )
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            model.refresh()
            model.resyncPhotoAuth()
            model.probeExtension()
            syncFloatingBall(enabled: model.floatingBallEnabled)
            FloatingBallController.shared.retryIfNeeded()
            // 回前台时若在录，确保常驻通知在（内容可能因保留时长变化而需要刷新）
            if model.systemCapturing {
                SaveNotification.post(retentionSeconds: Int(model.retentionSeconds), delay: 2)
            }
            SaveNotification.statusText { notifStatus = $0 }
        case .inactive, .background:
            // 后台悬浮球开着就保持显示（TrollStore 全局悬浮），否则按普通行为收起
            if !FloatingBallController.overlayInBackground {
                FloatingBallController.shared.hide()
            }
            // 关键：先刷新一次状态，否则读到的 systemCapturing 还是切走前的旧值(false)，
            // 会导致「开始录制后立刻切走 → 通知从没发出」。
            model.refresh()
            if model.systemCapturing {
                SaveNotification.post(retentionSeconds: Int(model.retentionSeconds))
            }
        @unknown default:
            break
        }
    }

    private func syncFloatingBall(enabled: Bool) {
        if enabled {
            FloatingBallController.shared.show(
                onTap: { model.saveRetro() },
                onLongPress: { model.stopRecordingReminder() }
            )
        } else {
            FloatingBallController.shared.hide()
        }
    }
}

// MARK: - 小组件

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct NoteRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
