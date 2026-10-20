/*
 * RetroSaveInGame —— 在游戏进程内绘制一颗悬浮按钮，点击触发「回溯」保存。
 *
 * 工作方式：
 *   只往游戏当前的 keyWindow 上加一颗 58x58 的圆形按钮。点击时通过 Darwin 通知
 *   （CFNotificationCenter）把指令发给正在录制的回溯广播扩展进程，游戏不会被切走。
 *   不 hook 任何游戏方法、不读写游戏内存、不修改游戏任何逻辑与数据。
 *
 * 交互：
 *   单击      = 保存最近 N 秒
 *   长按 0.8s = 在 30 / 60 / 120 秒之间切档
 *   拖动      = 挪位置（位置与档位存在游戏自己的 NSUserDefaults 里）
 *
 * 这是纯 Objective-C 动态库，不依赖 Logos / libsubstrate：
 * Substrate / ElleKit 会按同名 .plist 的 Filter 把本 dylib 注入目标进程，
 * 构造器跑起来即可，不需要任何 MS 符号。
 */

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define RR_BTN_SIZE 58
#define RR_TRIGGER_PREFIX @"com.retro.recorder.trigger."

static UIButton *g_btn = nil;
static NSInteger g_seconds = 60;
static BOOL g_pollInstalled = NO;

/* ---------- 指令发送 ---------- */

static void RRPostTrigger(void) {
    NSString *name = [RR_TRIGGER_PREFIX stringByAppendingFormat:@"%ld", (long)g_seconds];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, YES);
}

/* ---------- 确认录制进程收到了没有 ---------- */

#define RR_LOG_PREFIX @"com.retro.recorder.log."

static BOOL g_triggerAck = NO;
static BOOL g_ackOn = NO;

/* 扩展收到 trigger 后会立刻广播一条 TRIG_SAVE_<秒数> 日志。
   Darwin 通知在扩展侧偶发收不到（或被系统杀进程），这条回执是唯一能当场判断
   「指令到底有没有送达」的信号 —— 拿不到就直接拉起主 App 兜底，绝不静默失败。 */
static void RRAckCallback(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (!name) return;
    NSString *n = (__bridge NSString *)name;
    if (![n hasPrefix:RR_LOG_PREFIX]) return;
    NSString *body = [n substringFromIndex:[RR_LOG_PREFIX length]];
    if ([body hasPrefix:@"TRIG_SAVE"]) g_triggerAck = YES;
}

static void RRAckWatchBegin(void) {
    g_triggerAck = NO;
    if (g_ackOn) return;
    g_ackOn = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    RRAckCallback, NULL, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void RRAckWatchEnd(void) {
    if (!g_ackOn) return;
    g_ackOn = NO;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NULL, NULL);
}

static void RRFallbackToApp(NSInteger seconds) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"retrorecord://save?seconds=%ld", (long)seconds]];
    if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [app openURL:u options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [app openURL:u];
#pragma clang diagnostic pop
    }
}

/* ---------- 界面辅助 ---------- */

static UIWindow *RRKeyWindow(void) {
    if (![UIApplication respondsToSelector:@selector(sharedApplication)]) return nil;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    if ([app respondsToSelector:@selector(keyWindow)]) {
        UIWindow *k = app.keyWindow;
        if (k) return k;
    }
    for (UIWindow *w in app.windows) { if (w.isKeyWindow) return w; }
    return app.windows.firstObject;
}

static void RRToast(NSString *text) {
    UIWindow *w = RRKeyWindow();
    if (!w) return;
    UILabel *lb = [[UILabel alloc] init];
    lb.text = text;
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    lb.layer.cornerRadius = 10;
    lb.layer.masksToBounds = YES;
    lb.userInteractionEnabled = NO;
    lb.alpha = 0;
    CGFloat wd = 170, ht = 36;
    lb.frame = CGRectMake((w.bounds.size.width - wd) / 2, w.bounds.size.height - 130, wd, ht);
    [w addSubview:lb];
    [UIView animateWithDuration:0.18 animations:^{ lb.alpha = 1; } completion:^(BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.2 animations:^{ lb.alpha = 0; } completion:^(BOOL f2) {
                [lb removeFromSuperview];
            }];
        });
    }];
}

static void RRUpdateTitle(void) {
    [g_btn setTitle:[NSString stringWithFormat:@"回溯\n%lds", (long)g_seconds]
           forState:UIControlStateNormal];
}

/* ---------- 动作目标 ---------- */

@interface RRActions : NSObject
+ (instancetype)shared;
@end

@implementation RRActions

+ (instancetype)shared {
    static RRActions *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RRActions new]; });
    return s;
}

- (void)tapped {
    NSInteger sec = g_seconds;

    // 连发三次（0 / 0.25 / 0.5 秒）：单条 Darwin 通知偶发丢失时后面两次还能补上
    RRAckWatchBegin();
    RRPostTrigger();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPostTrigger(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPostTrigger(); });

    RRToast([NSString stringWithFormat:@"已请求保存最近 %ld 秒", (long)sec]);
    [UIView animateWithDuration:0.09 animations:^{
        g_btn.transform = CGAffineTransformMakeScale(1.18, 1.18);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.09 animations:^{ g_btn.transform = CGAffineTransformIdentity; }];
    }];

    // 1.8 秒后回执还没来 = 录制进程没收到（没在录 / 广播已被系统杀掉 / 通道没到）。
    // 这时直接拉起主 App 兜底保存：宁可短暂切出游戏一下，也绝不出现「点了没视频」。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL got = g_triggerAck;
        RRAckWatchEnd();
        if (got) {
            RRToast([NSString stringWithFormat:@"录制进程已收到，正在保存 %ld 秒", (long)sec]);
        } else {
            RRFallbackToApp(sec);
            RRToast(@"未检测到录制进程，已切到「回溯」保存");
        }
    });
}

- (void)longPressed:(UILongPressGestureRecognizer *)ges {
    if (ges.state != UIGestureRecognizerStateBegan) return;
    NSArray *options = @[@30, @60, @120];
    NSUInteger idx = [options indexOfObject:@(g_seconds)];
    if (idx == NSNotFound) idx = 0;
    g_seconds = [options[(idx + 1) % options.count] integerValue];
    [[NSUserDefaults standardUserDefaults] setInteger:g_seconds forKey:@"RetroSaveSeconds"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    RRUpdateTitle();
    RRToast([NSString stringWithFormat:@"回溯时长 %ld 秒", (long)g_seconds]);
}

- (void)panned:(UIPanGestureRecognizer *)ges {
    UIView *v = ges.view;
    CGPoint t = [ges translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [ges setTranslation:CGPointZero inView:v.superview];
    if (ges.state == UIGestureRecognizerStateEnded) {
        UIView *sup = v.superview;
        CGFloat half = v.bounds.size.width / 2;
        CGFloat x = MIN(MAX(8, v.center.x - half), MAX(8, sup.bounds.size.width - v.bounds.size.width - 8));
        CGFloat y = MIN(MAX(60, v.center.y - half), MAX(60, sup.bounds.size.height - v.bounds.size.height - 8));
        [UIView animateWithDuration:0.2 animations:^{
            v.center = CGPointMake(x + half, y + half);
        }];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setDouble:x forKey:@"RetroSaveBtnX"];
        [ud setDouble:y forKey:@"RetroSaveBtnY"];
        [ud synchronize];
    }
}

@end

/* ---------- 挂载 ---------- */

static void RRAttach(void) {
    UIWindow *w = RRKeyWindow();
    if (!w) return;

    if (!g_btn) {
        g_btn = [UIButton buttonWithType:UIButtonTypeCustom];
        g_btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        g_btn.layer.cornerRadius = RR_BTN_SIZE / 2.0;
        g_btn.layer.borderWidth = 1.2;
        g_btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        g_btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        g_btn.titleLabel.numberOfLines = 2;
        g_btn.titleLabel.textAlignment = NSTextAlignmentCenter;
        [g_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_btn.accessibilityLabel = @"RetroSave";

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSInteger saved = [ud integerForKey:@"RetroSaveSeconds"];
        if (saved > 0) g_seconds = saved;
        RRUpdateTitle();

        [g_btn addTarget:[RRActions shared] action:@selector(tapped)
         forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:[RRActions shared]
                                                          action:@selector(longPressed:)];
        lp.minimumPressDuration = 0.8;
        [g_btn addGestureRecognizer:lp];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[RRActions shared]
                                                     action:@selector(panned:)];
        [g_btn addGestureRecognizer:pan];

        CGFloat x = [ud doubleForKey:@"RetroSaveBtnX"];
        CGFloat y = [ud doubleForKey:@"RetroSaveBtnY"];
        if (x <= 0 || y <= 0) { x = 12; y = w.bounds.size.height / 2; }
        g_btn.frame = CGRectMake(x, y, RR_BTN_SIZE, RR_BTN_SIZE);
    }

    // 只在「按钮不在窗口里」或「窗口变了」时才重新挂，避免每 2 秒抖动
    if (g_btn.window == w && g_btn.superview == w) {
        [w bringSubviewToFront:g_btn];
        return;
    }
    [w addSubview:g_btn];   // addSubview 会自动把按钮从旧 window 摘下来
    [w bringSubviewToFront:g_btn];
}

__attribute__((constructor))
static void RRInit(void) {
    @autoreleasepool {
        // keyWindow 在进程刚起来时还没就绪：延迟 2.5s 挂一次；
        // 之后每次 keyWindow 变化再重挂；另外每 2s 兜底轮询一次（换场景/换 rootViewController 也能跟上）。
        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIWindowDidBecomeKeyNotification"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            RRAttach();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            RRAttach();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RRAttach();
            if (g_pollInstalled) return;
            g_pollInstalled = YES;
            dispatch_queue_t q = dispatch_get_main_queue();
            static dispatch_source_t timer = nil;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            if (!timer) return;
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(2.0 * NSEC_PER_SEC),
                                      (uint64_t)(0.5 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{ RRAttach(); });
            dispatch_resume(timer);
        });
    }
}
