import Foundation

/// 构建期变体开关。
///
/// 标准构建（默认，CI 产物 `RetroRecord-unsigned.ipa`）：
/// 完整功能版。带 App Group 权限，主 App 直接读分片、自己拼接导出；
/// 「后台悬浮球」可用（需 TrollStore + platform-application 权限）。
///
/// NO_APPGROUP 构建（CI 产物 `RetroRecord-noappgroup-unsigned.ipa`）：
/// 面向 iOS 17~27、用全能签安装、不依赖 App Group 的场景。
/// - AppGroup 永远判定为不可共享，全程走降级模式；
/// - 保存改由录制扩展自行拼接并写入系统相册（跨进程走 Darwin 通知）；
/// - 后台悬浮球依赖 platform-application 权限，全能签拿不到，该变体直接禁用；
/// - 不使用任何 App Group，全能签免费证书即可签名安装。
///
/// 编译方式（CI 与手动 Xcode 构建均适用）：
///     xcodebuild ... OTHER_SWIFT_FLAGS="-D NO_APPGROUP" archive
public enum RetroEnv {
    /// 是否强制无 App Group 模式。编译期决定，运行期不可改，
    /// 保证主 App 与录制扩展两个进程的判定永远一致。
    public static let noAppGroup: Bool = {
        #if NO_APPGROUP
        return true
        #else
        return false
        #endif
    }()

    /// 后台悬浮球是否可用。它需要 platform-application entitlement，
    /// 只有 TrollStore 直装能拿到；全能签 / 普通签名下一律禁用。
    public static var backgroundOverlayAvailable: Bool {
        !noAppGroup
    }

    /// 是否启用「跨 App / 桌面」的全局悬浮球（私有 FrontBoard Scene 方案）。
    ///
    /// ⚠️ 该方案在部分机型/iOS（已确认 iPad Pro 11" 二代 / iOS 15.4.1）上会让私有前台
    /// Scene 拦截「上滑回桌面」手势，导致整屏冻结、需硬重启脱困。
    /// 因此把它做成**手动开关、默认关闭**：编译期保留能力（=true），但 App 不在启动时
    /// 自动创建 Scene，必须由用户在「设置 → 后台悬浮球（实验·高风险）」里主动打开才建。
    /// 默认关闭 → 安装后开屏即安全；打开后若冻结，硬重启即可，重启后默认仍是关。
    public static let globalOverlayEnabled: Bool = true

    /// 变体标识（给界面显示），让用户能确认自己装的是哪一个包
    public static var variantLabel: String {
        noAppGroup ? "全能签版（无 App Group）" : "标准版"
    }
}
