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
        didSet { persist() }
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
        let segments = SegmentStore.allSegments()
        cachedSeconds = Double(segments.count) * SegmentStore.segmentSeconds
        cachedSizeBytes = SegmentStore.totalSizeBytes()
        extensionLogs = LogSink.shared.snapshot
        if savedFiles.isEmpty {
            savedFiles = Array(ExportStore.allExports().prefix(20))
        }
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
    }

    func markInterruptedHandled() {
        Heartbeat.clearInterruptedFlag()
        wasInterrupted = false
    }

    func stopRecordingReminder() {
        notice = Notice(text: "iOS 不允许 App 代用户停止录制。请下拉控制中心，点红色录屏按钮 → 停止。", isError: false)
    }

    // MARK: - 回溯保存

    func saveRetro() {
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
        exportProgress = "正在拼接最近 \(Int(retentionSeconds)) 秒…"
        let seconds = retentionSeconds
        let quality = exportQuality

        Task {
            do {
                let url = try await SegmentMerger.exportLast(seconds: seconds, quality: quality)
                savedFiles.insert(url, at: 0)
                ExportStore.prune()
                notice = Notice(text: "已保存最近 \(Int(seconds)) 秒，同时存入相册", isError: false)
                do {
                    try await PhotoSaver.save(videoAt: url)
                } catch {
                    notice = Notice(text: "视频已保存到 App 内，存入相册失败：\(error.localizedDescription)", isError: true)
                }
            } catch {
                notice = Notice(text: error.localizedDescription, isError: true)
            }
            isExporting = false
            exportProgress = nil
        }
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

        NotifyBridge.postSave(seconds: seconds)

        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            isExporting = false
            exportProgress = nil
            refresh()
            notice = Notice(
                text: "已请求导出最近 \(seconds) 秒。\n视频会直接写进「照片」App。\n下方「诊断」里有扩展回传的日志，能看到到底存没存成功。",
                isError: false
            )
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
