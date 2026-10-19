#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <sys/ptrace.h>
#import <sys/sysctl.h>
#import <unistd.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif

/// 防篡改保护壳。
///
/// 以 `+load` 实现：ObjC 类在 App 启动最早阶段（main 之前）自动加载，
/// 早于任何业务代码，因此不需要改动任何现有源码即可生效。
///
/// 四道检查：
/// 1. ptrace(PT_DENY_ATTACH) 阻止调试器附加；
/// 2. sysctl P_TRACED 检测是否已被调试；
/// 3. 遍历 dyld 镜像，检测 Frida / Cycript / Substrate 等注入；
/// 4. 防二次重签：检测 embedded.mobileprovision 与沙盒存在
///    （TrollStore 安装的包不带 provision、且带 no-sandbox 无沙盒）。
///
/// ⚠️ 第 4 项只在标准版（TrollStore）生效：全能签变体编译时定义了 NO_APPGROUP，
///    它本来就带 provision 且有沙盒，必须跳过检测，否则会误杀自己。
@interface RetroAntiTamper : NSObject
@end

@implementation RetroAntiTamper

+ (void)load {
    [self denyDebugger];

    if ([self isBeingDebugged]) {
        [self bailWithReason:@"检测到调试器附加，程序已停止。"];
        return;
    }

    if ([self hasInjectedLibraries]) {
        [self bailWithReason:@"检测到非法注入，程序已停止。"];
        return;
    }

#ifndef NO_APPGROUP
    if ([self hasEmbeddedProvision]) {
        [self bailWithReason:@"签名环境异常：此版本需通过 TrollStore 安装，不能被重新签名分发。"];
        return;
    }

    if ([self isSandboxed]) {
        [self bailWithReason:@"运行环境异常：缺少 TrollStore 权限，程序已停止。"];
        return;
    }
#endif
}

#pragma mark - 反调试

+ (void)denyDebugger {
    ptrace(PT_DENY_ATTACH, 0, 0, 0);
}

+ (BOOL)isBeingDebugged {
    int mib[4];
    struct kinfo_proc info;
    size_t size = sizeof(info);
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PID;
    mib[3] = getpid();
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    }
    return NO;
}

#pragma mark - 反注入

+ (BOOL)hasInjectedLibraries {
    static NSArray<NSString *> *suspects = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suspects = @[
            @"frida",
            @"cycript",
            @"substrate",
            @"substitute",
            @"sslkillswitch",
            @"appsync",
            @"libflex",
            @"dobby",
            @"shadow",
            @"tweakinject",
            @"zzzsubstrate",
        ];
    });

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) { continue; }
        NSString *lower = [[NSString stringWithUTF8String:name] lowercaseString];
        if (!lower) { continue; }
        for (NSString *s in suspects) {
            if ([lower containsString:s]) { return YES; }
        }
    }
    return NO;
}

#pragma mark - 防二次重签（仅标准版）

/// TrollStore 安装的包不带 embedded.mobileprovision；普通重签（全能签/Sideloadly）会带
+ (BOOL)hasEmbeddedProvision {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
    if (path.length > 0) { return YES; }
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *p2 = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    return [[NSFileManager defaultManager] fileExistsAtPath:p2];
}

/// platform-application + no-sandbox 下可写 /var/mobile；被普通签名重签后会被沙盒挡住
+ (BOOL)isSandboxed {
    NSString *probe = @"/var/mobile/Library/Preferences/com.retro.recorder.probe";
    NSData *data = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = [data writeToFile:probe atomically:YES];
    if (ok) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        return NO;
    }
    return YES;
}

#pragma mark - 触发后处理

+ (void)bailWithReason:(NSString *)reason {
    NSLog(@"[antitamper] %@", reason);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 尝试弹窗告知，再退出（+load 阶段还没有 window，这里延后到界面就绪）
        UIViewController *root = [self topViewController];
        if (root) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法运行"
                                                                          message:reason
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [root presentViewController:alert animated:NO completion:nil];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    });
}

+ (UIViewController *)topViewController {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) { return nil; }
    UIViewController *root = nil;
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) { continue; }
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && w.rootViewController) { root = w.rootViewController; break; }
            }
        }
    }
    if (!root) {
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow && w.rootViewController) { root = w.rootViewController; break; }
        }
    }
    return root;
}

@end
