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

    private var pollTimer: Timer?

    init() {
        let config = RecorderConfigStore.load()
        retentionSeconds = config.retentionSeconds
        bitrateMbps = config.bitrateMbps
        microphoneEnabled = config.microphoneEnabled
        refresh()
        startPolling()

        // 扩展进程没有 UI，自己弹不出权限框，必须由主 App 先把相册权限要下来
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
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
        if savedFiles.isEmpty {
            savedFiles = Array(ExportStore.allExports().prefix(20))
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

        let name = "com.retro.recorder.save.\(seconds)"
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )

        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            isExporting = false
            exportProgress = nil
            notice = Notice(
                text: "已请求导出最近 \(seconds) 秒。\n受安装方式限制，视频会直接存进「照片」App，App 内列表读不到。\n如果相册里没有，请到 设置 → 回溯 → 照片 里允许「添加照片」。",
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
