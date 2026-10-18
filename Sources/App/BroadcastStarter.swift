import ReplayKit
import SwiftUI
import UIKit

/// 系统录屏选择器。
///
/// iOS 13 之后，App 无法直接启动 Broadcast，只能把系统弹层拉起来，由用户本人点击"开始录制"。
/// 这是刻意的设计：任何 App 想录制整块屏幕，都必须经过用户这一次真实触控。
/// 本组件做的事是把系统按钮换成我们自己的外观，并挂一个 touchDown 回调，
/// 用来在用户点击的瞬间准备好常驻胶囊与设置。
struct BroadcastStarter: UIViewRepresentable {
    let title: String
    let systemImage: String
    let background: UIColor
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 260, height: 52))
        picker.preferredExtension = AppIdentifiers.broadcastUploadExtension
        picker.showsMicrophoneButton = false
        DispatchQueue.main.async { configure(picker, coordinator: context.coordinator) }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = AppIdentifiers.broadcastUploadExtension
        uiView.showsMicrophoneButton = false
        configure(uiView, coordinator: context.coordinator)
    }

    private func configure(_ picker: RPSystemBroadcastPickerView, coordinator: Coordinator) {
        guard !coordinator.didAttach, let control = Self.firstControl(in: picker) else { return }
        coordinator.didAttach = true
        control.addTarget(coordinator, action: #selector(Coordinator.tapped), for: .touchDown)
        if let button = control as? UIButton {
            var configuration = UIButton.Configuration.filled()
            configuration.title = title
            configuration.image = UIImage(systemName: systemImage)
            configuration.imagePlacement = .leading
            configuration.imagePadding = 8
            configuration.baseBackgroundColor = background
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
            button.configuration = configuration
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    private static func firstControl(in view: UIView) -> UIControl? {
        if let control = view as? UIControl, !(control is UISwitch), !(control is UISlider) {
            return control
        }
        for subview in view.subviews {
            if let found = firstControl(in: subview) { return found }
        }
        return nil
    }

    final class Coordinator: NSObject {
        let onTap: () -> Void
        var didAttach = false

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
            super.init()
        }

        @objc func tapped() {
            onTap()
        }
    }
}
