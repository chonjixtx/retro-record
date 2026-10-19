#import "OverlayBridge.h"
#import "OverlayPrivate.h"
#import <dlfcn.h>
#import <dispatch/dispatch.h>

/// 浮动 Scene 的标识。必须同时满足两处一致：
///   1. 本文件的 FBSSceneIdentity identifier
///   2. RetroAppDelegate.configurationForConnecting 里的 persistentIdentifier 判断
/// 注意：这个 Scene 是「空锚」，里面绝不建窗口；悬浮窗口由 FloatingBallController
/// 在 shellReady 回调后以「不挂 windowScene 的独立 UIWindow」创建。
static NSString *const kOverlaySceneIdentifier = @"retrooverlay";

static BOOL sStarted = NO;
static BOOL sSceneCreated = NO;
static id sFloatingScene = nil;                       // FBScene，必须强引用
static UIRootWindowScenePresentationBinder *sSceneBinder = nil; // binder 持 scene，也要强引用
static __weak UIWindow *sOverlayWindow = nil;
static FBSOrientationObserver *sOrientationObserver = nil;
static void (^sShellReadyHandler)(void) = nil;        // Scene 建好后回调 Swift

typedef void (*FBSystemShellInitializeFn)(id);

static void LoadPrivateFrameworks(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_LAZY);
}

/// FBSystemShellInitialize 是私有 C 函数，没有公开符号表，逐个框架 dlsym 找。
static FBSystemShellInitializeFn ResolveFBSystemShellInitialize(void) {
    static const char *kPaths[] = {
        "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
        "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
    };
    for (size_t i = 0; i < sizeof(kPaths) / sizeof(kPaths[0]); i++) {
        void *handle = dlopen(kPaths[i], RTLD_LAZY);
        if (!handle) { continue; }
        FBSystemShellInitializeFn fn = (FBSystemShellInitializeFn)dlsym(handle, "FBSystemShellInitialize");
        if (fn) { return fn; }
    }
    return NULL;
}

@implementation OverlayBridge

+ (void)startOverlayScene {
    if (sStarted) { return; }
    sStarted = YES;

    // 建 Scene 属于 UI 相关工作，统一回到主线程
    void (^work)(id) = ^(id unused) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createFloatingScene];
            [self startOrientationObserver];
        });
    };

    FBSystemShellInitializeFn fn = ResolveFBSystemShellInitialize();
    if (fn) {
        fn(work);
    } else {
        // 解析不到符号（系统大改版）：直接建，成不成随缘
        work(nil);
    }
}

+ (void)createFloatingScene {
    if (sSceneCreated) { return; }
    LoadPrivateFrameworks();

    @try {
        if (!NSClassFromString(@"FBSceneManager") ||
            !NSClassFromString(@"UIRootWindowScenePresentationBinder") ||
            !NSClassFromString(@"UIApplicationSceneSpecification")) {
            NSLog(@"[overlay] private classes unavailable");
            return;
        }

        FBSceneManager *manager = [FBSceneManager sharedInstance];
        if (!manager) { return; }

        FBSMutableSceneDefinition *definition = [FBSMutableSceneDefinition definition];
        definition.identity = [FBSSceneIdentity identityForIdentifier:kOverlaySceneIdentifier];
        definition.clientIdentity = [FBSSceneClientIdentity localIdentity];
        definition.specification = [UIApplicationSceneSpecification specification];

        FBSMutableSceneParameters *parameters =
            [FBSMutableSceneParameters parametersForSpecification:definition.specification];

        UIMutableApplicationSceneSettings *settings = [UIMutableApplicationSceneSettings new];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.frame = UIScreen.mainScreen._referenceBounds; // 全屏
        settings.level = 1;
        settings.foreground = YES;                // 关键：Scene 永远处于前台
        settings.interfaceOrientation = UIInterfaceOrientationPortrait;
        settings.deviceOrientationEventsEnabled = YES;
        // 关键：忽略被 SpringBoard 等系统 App 遮挡，否则回到桌面就被挡了
        [settings.ignoreOcclusionReasons addObject:@"SystemApp"];
        parameters.settings = settings;

        UIMutableApplicationSceneClientSettings *clientSettings = [UIMutableApplicationSceneClientSettings new];
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
        parameters.clientSettings = clientSettings;

        id scene = [manager createSceneWithDefinition:definition initialParameters:parameters];
        if (!scene) {
            NSLog(@"[overlay] createSceneWithDefinition returned nil");
            return;
        }

        UIRootWindowScenePresentationBinder *binder =
            [[UIRootWindowScenePresentationBinder alloc] initWithPriority:0
                                                    displayConfiguration:settings.displayConfiguration];
        [binder addScene:scene];

        // scene / binder 互相强引用，保证活到 App 生命周期结束
        sFloatingScene = scene;
        sSceneBinder = binder;
        sSceneCreated = YES;
        NSLog(@"[overlay] floating scene created: %@", kOverlaySceneIdentifier);

        // 通知 Swift 侧：锚定 Scene 已就绪，可以建「不挂 windowScene 的独立悬浮窗口」了。
        // 注意：悬浮窗口绝不能建在这个浮动 Scene 里（Scene 内窗口的空白触摸不会跨 Scene
        // 下传，会整屏卡死）；原项目的做法是 Scene 只做空锚，窗口建在 App 进程的无 Scene 空间。
        if (sShellReadyHandler) {
            dispatch_async(dispatch_get_main_queue(), sShellReadyHandler);
        }
    } @catch (NSException *exception) {
        NSLog(@"[overlay] createFloatingScene exception: %@", exception);
    }
}

/// 设备旋转时，浮动 Scene 的窗口不会自动旋转，用系统方向监听手动转
+ (void)startOrientationObserver {
    if (sOrientationObserver) { return; }
    @try {
        if (!NSClassFromString(@"FBSOrientationObserver")) { return; }
        FBSOrientationObserver *observer = [FBSOrientationObserver new];
        [observer setHandler:^(FBSOrientationUpdate *update) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *window = sOverlayWindow;
                if (!window) { return; }
                [window _rotateWindowToOrientation:update.orientation
                                   updateStatusBar:YES
                                           duration:update.duration
                                     skipCallbacks:NO];
            });
        }];
        sOrientationObserver = observer;
    } @catch (NSException *exception) {
        NSLog(@"[overlay] orientation observer exception: %@", exception);
    }
}

+ (void)setShellReadyHandler:(void (^)(void))handler {
    sShellReadyHandler = handler;
}

+ (void)attachOverlayWindow:(UIWindow *)window {
    sOverlayWindow = window;
}

+ (void)teardown {
    @try {
        [sOrientationObserver invalidate];
    } @catch (NSException *exception) {
        NSLog(@"[overlay] teardown exception: %@", exception);
    }
    sOrientationObserver = nil;
    sOverlayWindow = nil;

    // 真正把浮动 Scene 从系统移除，避免关闭后冻结残留
    @try {
        if (sFloatingScene && NSClassFromString(@"FBSceneManager")) {
            FBSceneManager *manager = [FBSceneManager sharedInstance];
            if ([manager respondsToSelector:@selector(removeScene:)]) {
                [manager removeScene:sFloatingScene];
            } else if ([manager respondsToSelector:@selector(destroyScene:)]) {
                [manager performSelector:@selector(destroyScene:) withObject:sFloatingScene];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[overlay] teardown removeScene exception: %@", exception);
    }
    sFloatingScene = nil;
    sSceneBinder = nil;
    sSceneCreated = NO;
    sStarted = NO;
}

@end
