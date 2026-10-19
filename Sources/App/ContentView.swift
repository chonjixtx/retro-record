import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
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
        }
        .onChange(of: model.exportQuality) { _ in model.persist() }
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
                         : "降级模式：分片写在录制扩展自己的沙盒里，点保存后直接进相册")
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

                Text(model.extensionAliveText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
                NoteRow(text: "悬浮球只在本 App 前台可见。切到别的 App 后要点返回本 App 才能保存。")
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
        case .inactive, .background:
            FloatingBallController.shared.hide()
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
