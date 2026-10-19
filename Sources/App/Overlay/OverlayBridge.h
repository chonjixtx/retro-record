#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局悬浮窗（TrollStore 专用）的 Objective-C 桥接层。
///
/// 原理：通过 FrontBoard 私有 API 创建一个独立的「浮动 Scene」，
/// 这个 Scene 的 settings.foreground = YES 且 ignoreOcclusionReasons 含 "SystemApp"，
/// 因此它的窗口在 App 退到后台、回到桌面、甚至锁屏时依然压在最上层。
/// 普通签名（含全能签）没有 platform-application 权限，创建会失败，自动降级为 App 内悬浮球。
@interface OverlayBridge : NSObject

/// 启动浮动 Scene。请在 application:didFinishLaunchingWithOptions: 里调用一次，重复调用无效。
+ (void)startOverlayScene;

/// Swift 侧把浮动 Scene 的窗口交给桥接层（设备旋转时用它同步旋转窗口）。传 nil 表示解绑。
+ (void)attachOverlayWindow:(nullable UIWindow *)window;

/// 停掉方向监听（一般用不到，预留）。
+ (void)teardown;

@end

NS_ASSUME_NONNULL_END
