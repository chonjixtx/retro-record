import AVFoundation
import Foundation
import Photos
import SwiftUI
import UIKit

struct Notice: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var retentionSeconds: Double = 600 {
        didSet {
            persist()
            // 降级模式下扩展读不到主 App 的配置文件，保留秒数得单独同步过去
            NotifyBridge.postConfig(retentionSeconds: Int(retentionSeconds))
        }
    }
    @Published var bitrateMbps: Double = 6 {
        didSet { persist() }
    }
    @Published var microphoneEnabled: Bool = false {
        didSet { persist() }
    }
    @Published var exportQuality: ExportQuality = .p1080
    @Published var floatingBallEnabled: Bool = true

    @Published var isRecording = false
    @Published var wasInterrupted = false
    @Published var cachedSeconds: Double = 0
    @Published var cachedSizeBytes: UInt64 = 0
    @Published var isExporting = false
    @Published var exportProgress: String?
    @Published var notice: Notice?
    @Published var savedFiles: [URL] = []
    @Published var showingShareURL: URL?
    @Published var extensionLogs: [String] = []
    /// 扩展落盘到共享目录的日志。主 App 挂起时收不到 Darwin 通知，这份是补看的
    @Published var extFileLogs: [String] = []
    /// 系统层面是否正在录屏。`UIScreen.isCaptured` 在主 App 进程内就能读到，
    /// 不需要跨进程通信 —— 这是判断"到底在不在录"最可靠的一个信号
    @Published var systemCapturing = false

    private var pollTimer: Timer?

    init() {
        let config = RecorderConfigStore.load()
        retentionSeconds = config.retentionSeconds
        bitrateMbps = config.bitrateMbps
        microphoneEnabled = config.microphoneEnabled
        photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        LogBridge.start()
        refresh()
        startPolling()
    }

    // MARK: - 相册权限

    @Published var photoAuthStatus: PHAuthorizationStatus = .notDetermined

    var photoAuthText: String {
        switch photoAuthStatus {
        case .authorized, .limited: return "相册权限：已允许"
        case .denied, .restricted: return "相册权限：已拒绝，视频无法存入相册"
        case .notDetermined: return "相册权限：未请求"
        @unknown default: return "相册权限：未知"
        }
    }

    /// 扩展进程没有 UI，权限必须由主 App 请求
    func requestPhotoAuth() {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        photoAuthStatus = current
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                Task { @MainActor in
                    self?.photoAuthStatus = status
                }
            }
            return
        }
        // 已经拒绝过就没法再弹框了，只能把用户送去设置页
        if current == .denied || current == .restricted {
            openSystemSettings()
        }
    }

    /// 从设置页切回来时同步一下权限，避免界面还显示旧状态
    func resyncPhotoAuth() {
        photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - 状态轮询

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        let recording = Heartbeat.isRecording()
        isRecording = recording
        wasInterrupted = Heartbeat.wasInterrupted()
        extensionLogs = LogSink.shared.snapshot
        // 扩展落盘的日志：主 App 挂起期间漏收的那些，这里能补回来
        extFileLogs = ExtLogFile.readTail(30)
        if AppGroup.isShared {
            let segments = SegmentStore.allSegments()
            cachedSeconds = Double(segments.count) * SegmentStore.segmentSeconds
            cachedSizeBytes = SegmentStore.totalSizeBytes()
        } else {
            // 降级模式：主 App 读不到分片目录，缓存时长只能从扩展心跳日志反推
            cachedSeconds = Self.estimateCachedSeconds(from: extensionLogs)
            cachedSizeBytes = 0
        }
        systemCapturing = UIScreen.main.isCaptured
        // 降级模式没有共享配置文件：用户改秒数时扩展可能还没起录（监听还没挂上），
        // 所以这里持续补发一次，保证扩展起来后一定能拿到正确的保留时长
        if !AppGroup.isShared {
            NotifyBridge.postConfig(retentionSeconds: Int(retentionSeconds))
        }
        if savedFiles.isEmpty {
            savedFiles = Array(ExportStore.allExports().prefix(20))
        }
    }

    var captureText: String {
        systemCapturing ? "系统录制：进行中（状态栏应有红色标记）" : "系统录制：未开启"
    }

    /// 降级模式下主 App 读不到分片目录，缓存时长只能从扩展心跳日志反推：
    /// 扩展每写完一片就报一次 SEG_OK_<数量>，主 App 探活时也会报 SEGS_<数量>。
    static func estimateCachedSeconds(from logs: [String]) -> Double {
        var count = 0
        for line in logs {
            for marker in ["SEG_OK_", "SEGS_"] {
                guard let range = line.range(of: marker) else { continue }
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                if let value = Int(digits) {
                    count = max(count, value)
                }
            }
        }
        return Double(count) * SegmentStore.segmentSeconds
    }

    /// 降级模式下的缓存状态文案
    var degradedCacheText: String {
        if cachedSeconds >= SegmentStore.segmentSeconds {
            return "已缓存约 \(cachedDurationText)（按扩展心跳估算）· 分片在录制扩展沙盒里，保存后直接进相册"
        }
        return "降级模式：分片写在录制扩展自己的沙盒里，点保存后直接进相册"
    }

    /// 最近一条扩展日志（去掉主 App 自己写的那部分）
    var lastExtensionLine: String? {
        extensionLogs.last { !$0.contains(" APP ") }
    }

    /// 扩展是否在产出分片。降级模式下看不了共享目录，只能看日志里有没有 SEG_OK
    var extensionAliveText: String {
        let hits = extensionLogs.filter { $0.contains("SEG_OK") || $0.contains("EXT_START") }
        if let last = hits.last {
            return "扩展最近心跳：" + last
        }
        return "扩展暂无心跳（没在录，或日志通道未通）"
    }

    private var authTag: String {
        switch photoAuthStatus {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    func clearLogs() {
        LogSink.shared.clear()
        refresh()
    }

    /// 主动问一下扩展还在不在。App 进程被系统杀掉重启后，之前的日志全丢了，
    /// 只有靠这个才能立刻拿到当前状态
    /// 版本号（诊断区显示）。装了哪一期构建，一眼就能确认
    var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(short)（build \(build)）"
    }

    func clearExtLogFile() {
        ExtLogFile.clear()
        extFileLogs = []
    }

    /// 发一条和游戏内按钮一模一样的保存指令（trigger 通道，60 秒）。
    ///
    /// 用来把「指令根本没送到扩展」和「扩展收到了但导出失败」区分开：
    /// 点完看日志区有没有 TRIG_SAVE_60 —— 没有就是通道不通，有就是导出环节的问题。
    /// 这一步在 App 内就能做，不用进游戏，比真机试错快得多。
    func testTriggerChannel() {
        LogBridge.local("TRIG_TEST_SENT_60")
        NotifyBridge.postTrigger(seconds: 60)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refresh()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refresh()
        }
    }

    func probeExtension() {
        LogBridge.local("PING_SENT")
        NotifyBridge.postPing()
        refresh()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refresh()
        }
    }

    func persist() {
        let config = RecorderConfig(
            retentionSeconds: retentionSeconds,
            bitrateMbps: bitrateMbps,
            microphoneEnabled: microphoneEnabled
        )
        RecorderConfigStore.save(config)
    }

    // MARK: - 录制

    func willStartRecording() {
        // 用户在系统弹层里点"开始录制"前，先把配置落盘给扩展
        persist()
        // 降级模式没共享目录，配置只能走通知通道送过去
        NotifyBridge.postConfig(retentionSeconds: Int(retentionSeconds))
        // 此刻 App 一定在前台，是挂常驻通知最可靠的时机。
        // 延后 3 秒投递：等系统选择器/录制启动后 App 已退后台，通知才会进通知中心列表
        // （前台 App 自己的通知 iOS 不放进通知中心列表）。
        SaveNotification.post(retentionSeconds: Int(retentionSeconds), delay: 3)
        // 兜底：若 25 秒内没真正开始录（用户取消了系统选择器），把通知撤掉
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self else { return }
            if !self.systemCapturing && !Heartbeat.isRecording() { SaveNotification.cancel() }
        }
    }

    func markInterruptedHandled() {
        Heartbeat.clearInterruptedFlag()
        wasInterrupted = false
    }

    func stopRecordingReminder() {
        notice = Notice(text: "iOS 不允许 App 代用户停止录制。请下拉控制中心，点红色录屏按钮 → 停止。", isError: false)
    }

    // MARK: - 回溯保存

    func saveRetro(seconds overrideSeconds: Double? = nil) {
        guard !isExporting else { return }

        // 降级模式：主 App 读不到分片，只能通知录制扩展自己导出到相册
        if !AppGroup.isShared {
            requestExportFromExtension()
            return
        }

        guard cachedSeconds >= 1 else {
            notice = Notice(text: "缓存里还没有画面，先开始录制并保持屏幕不锁屏", isError: true)
            return
        }

        isExporting = true
        let seconds = overrideSeconds ?? retentionSeconds
        exportProgress = "正在拼接最近 \(Int(seconds)) 秒…"
        let quality = exportQuality

        // 关键修复：Swift 5 并发模式下 nonisolated async 函数会继承调用方的
        // actor 上下文。这里若写 Task { }，整段「拷贝分片 + 建 composition +
        // 导出」都会跑在主线程 —— 表现就是点保存后界面卡死。
        // Task.detached 强制脱离 MainActor，UI 更新再切回主线程。
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try await SegmentMerger.exportLast(seconds: seconds, quality: quality)
                await self?.finishExport(url: url, seconds: seconds)
            } catch {
                await self?.failExport(error)
            }
        }
    }

    @MainActor
    private func finishExport(url: URL, seconds: Double) {
        savedFiles.insert(url, at: 0)
        ExportStore.prune()
        isExporting = false
        exportProgress = nil
        notice = Notice(text: "已保存最近 \(Int(seconds)) 秒，同时存入相册", isError: false)
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await PhotoSaver.save(videoAt: url)
            } catch {
                await self?.failPhoto(error)
            }
        }
    }

    @MainActor
    private func failExport(_ error: Error) {
        isExporting = false
        exportProgress = nil
        notice = Notice(text: error.localizedDescription, isError: true)
    }

    @MainActor
    private func failPhoto(_ error: Error) {
        notice = Notice(text: "视频已保存到 App 内，存入相册失败：\(error.localizedDescription)", isError: true)
    }

    /// 跨 App 触发保存：retrorecord://save?seconds=60
    ///
    /// iOS 不允许任何 App 的窗口浮在别的 App 之上，所以「游戏里点球保存」
    /// 唯一真正可用的替代，是借助系统自己的悬浮层——辅助触控小白点：
    /// 小白点 → 快捷指令 → 打开 retrorecord://save → 本 App 被拉起并保存。
    /// 代价是短暂离开游戏，换来 100% 可用（不依赖任何私有 API）。
    @MainActor
    func saveFromDeepLink(seconds: Double?) {
        // 刚被拉起时缓存时长还是旧值，必须先刷新再判断
        refresh()
        saveRetro(seconds: seconds)
    }

    func open(_ url: URL) {
        showingShareURL = url
    }

    /// 降级模式下的保存：通过系统级 Darwin 通知让录制扩展自己拼接，
    /// 秒数编码在通知名里（Darwin 通知传不了 payload）。
    private func requestExportFromExtension() {
        let seconds = Int(retentionSeconds)
        isExporting = true
        exportProgress = "已通知录制扩展导出，请稍候…"
        LogBridge.local("SAVE_POST_\(seconds)")
        LogBridge.local("AUTH_\(authTag)")

        let baseline = LogSink.shared.snapshot.count
        NotifyBridge.postSave(seconds: seconds)
        refresh()

        Task {
            // 3 秒内扩展应该回一条 SAVE_REQ，没有就是没收到
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let fresh = Array(LogSink.shared.snapshot.dropFirst(baseline))
            let acked = fresh.contains { $0.contains("SAVE_REQ") }
            refresh()

            if acked {
                exportProgress = "扩展已接手，正在拼接…"
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                isExporting = false
                exportProgress = nil
                refresh()
                let after = Array(LogSink.shared.snapshot.dropFirst(baseline))
                let photoOK = after.contains { $0.contains("PHOTO_OK") || $0.contains("PARTS_OK") }
                if photoOK {
                    notice = Notice(
                        text: "已保存最近 \(seconds) 秒，去「照片」App 的最近项目里就能看到。",
                        isError: false
                    )
                } else {
                    notice = Notice(
                        text: "扩展已收到请求，但还没确认写入相册。\n看下面「诊断」里的日志：出现 PHOTO_FAIL 就是相册权限问题。",
                        isError: true
                    )
                }
                return
            }

            isExporting = false
            exportProgress = nil
            let hint = systemCapturing
                ? "录制是开着的，但录制扩展没有回应保存请求。\n改用保底办法：下拉控制中心 → 点红色录制按钮停止 → 视频会自动存进相册。"
                : "现在没有在录屏。\n先点「开始录制」→ 选「回溯录制」→ 开始直播，等 30 秒后再点保存。"
            notice = Notice(text: hint, isError: true)
        }
    }

    /// 录屏状态变化 → 挂上/撤掉常驻通知。
    /// 撤掉必须延时确认：刚开始录屏时 `isCaptured` 可能短暂闪 false，
    /// 立即 cancel 会把刚发出的通知删掉，造成「通知从来没出现过」的假象。
    private var notifCancelTask: Task<Void, Never>?

    func handleCaptureChanged(_ capturing: Bool) {
        notifCancelTask?.cancel()
        if capturing {
            SaveNotification.post(retentionSeconds: Int(retentionSeconds))
            return
        }
        notifCancelTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.systemCapturing && !Heartbeat.isRecording() {
                SaveNotification.cancel()
            }
        }
    }

    func clearCache() {
        SegmentStore.removeAll()
        refresh()
        notice = Notice(text: "环形缓冲已清空", isError: false)
    }

    // MARK: - 展示辅助

    var cachedSizeText: String {
        let mb = Double(cachedSizeBytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    var cachedDurationText: String {
        let total = Int(cachedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum PhotoSaver {
    static func save(videoAt url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MergerError.exportFailed(nil))
                }
            }
        }
    }
}
