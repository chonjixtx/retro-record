/*
 * RetroSaveInGame —— 在游戏进程内绘制一个悬浮窗：悬浮球 + 控制面板。
 *
 * 工作方式：
 *   只往游戏当前的 keyWindow 上加视图，不 hook 任何游戏方法、不读写游戏内存、
 *   不修改游戏任何逻辑与数据。所有指令都通过 Darwin 通知（CFNotificationCenter）
 *   发给正在录制的回溯广播扩展进程，游戏不会被切走。
 *
 * 面板能做的事：
 *   1. 开启录屏：用系统公开的 RPSystemBroadcastPickerView（preferredExtension
 *      指向 com.retro.recorder.broadcast）。点一下就弹出系统的「开始直播」面板，
 *      ——弹窗是从游戏进程发起的，所以直接盖在游戏上面，不用切出游戏。
 *   2. 保存最近 N 秒：发 trigger 通知，带 1.8 秒回执判断，没回执就拉起主 App 兜底。
 *   3. 时长档位 30 / 60 / 120 秒。
 *   4. 码率档位 4 / 6 / 8 / 12 Mbps，下一段分片生效。
 *
 * 交互：
 *   单击悬浮球 = 展开/收起面板
 *   长按悬浮球 = 立刻保存最近 N 秒（不用展开面板）
 *   拖动悬浮球 = 挪位置（位置、时长、码率存在游戏自己的 NSUserDefaults 里）
 *
 * 这是纯 Objective-C 动态库，不依赖 Logos / libsubstrate：
 * Substrate / ElleKit 会按同名 .plist 的 Filter 把本 dylib 注入目标进程，
 * 构造器跑起来即可，不需要任何 MS 符号。
 */

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ReplayKit/ReplayKit.h>
#import <objc/runtime.h>

#define RR_BTN_SIZE 58
#define RR_TRIGGER_PREFIX @"com.retro.recorder.trigger."
#define RR_LOG_PREFIX @"com.retro.recorder.log."
#define RR_BITRATE_PREFIX @"com.retro.recorder.bitrate."
#define RR_BROADCAST_EXT @"com.retro.recorder.broadcast"
#define RR_PANEL_W 224

static UIButton *g_btn = nil;
static UIView *g_panel = nil;
static UILabel *g_status = nil;
static UISegmentedControl *g_segSeconds = nil;
static UISegmentedControl *g_segBitrate = nil;
static NSInteger g_seconds = 60;
static NSInteger g_bitrate = 6;
static BOOL g_pollInstalled = NO;

/* ---------- 指令发送 ---------- */

static void RRPost(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, YES);
}

static void RRPostTrigger(void) {
    RRPost([RR_TRIGGER_PREFIX stringByAppendingFormat:@"%ld", (long)g_seconds]);
}

static void RRPostBitrate(void) {
    RRPost([RR_BITRATE_PREFIX stringByAppendingFormat:@"%ld", (long)g_bitrate]);
}

/* ---------- 确认录制进程收到了没有 ---------- */

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
    lb.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    lb.layer.cornerRadius = 10;
    lb.layer.masksToBounds = YES;
    lb.userInteractionEnabled = NO;
    lb.alpha = 0;
    CGFloat wd = 200, ht = 36;
    lb.frame = CGRectMake((w.bounds.size.width - wd) / 2, w.bounds.size.height - 140, wd, ht);
    [w addSubview:lb];
    [w bringSubviewToFront:lb];
    [UIView animateWithDuration:0.18 animations:^{ lb.alpha = 1; } completion:^(BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.2 animations:^{ lb.alpha = 0; } completion:^(BOOL f2) {
                [lb removeFromSuperview];
            }];
        });
    }];
}

static void RRSetStatus(NSString *text) {
    if (g_status) {
        g_status.text = text;
        g_status.alpha = 1;
    }
    RRToast(text);
}

static void RRUpdateTitle(void) {
    [g_btn setTitle:[NSString stringWithFormat:@"回溯\n%lds", (long)g_seconds]
           forState:UIControlStateNormal];
}

static void RRSavePrefs(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:g_seconds forKey:@"RetroSaveSeconds"];
    [ud setInteger:g_bitrate forKey:@"RetroSaveBitrate"];
    [ud synchronize];
}

/* 把面板摆到悬浮球旁边（球在左半屏就放右边，反之放左边），并夹在窗口内 */
static void RRPositionPanel(void) {
    if (!g_panel || !g_btn || !g_btn.superview) return;
    UIView *sup = g_btn.superview;
    CGFloat bw = sup.bounds.size.width;
    CGFloat bh = sup.bounds.size.height;
    CGFloat ph = g_panel.bounds.size.height;
    CGFloat pw = RR_PANEL_W;

    CGFloat x;
    if (g_btn.center.x < bw / 2) {
        x = CGRectGetMaxX(g_btn.frame) + 8;
    } else {
        x = CGRectGetMinX(g_btn.frame) - pw - 8;
    }
    x = MIN(MAX(8, x), MAX(8, bw - pw - 8));
    CGFloat y = MIN(MAX(70, CGRectGetMinY(g_btn.frame) - 10), MAX(70, bh - ph - 10));
    g_panel.frame = CGRectMake(x, y, pw, ph);
    [sup bringSubviewToFront:g_panel];
}

/* ---------- 面板 ---------- */

static void RRBuildPanel(void) {
    if (g_panel) return;

    CGFloat pw = RR_PANEL_W;
    CGFloat pad = 12;
    CGFloat y = 0;

    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 10)];
    p.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    p.layer.cornerRadius = 14;
    p.layer.borderWidth = 1;
    p.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    p.layer.masksToBounds = YES;

    // 标题栏
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 36)];
    bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [p addSubview:bar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 0, pw - 70, 36)];
    title.text = @"回溯 · 游戏内控制";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [bar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(pw - 40, 3, 32, 30);
    [close setTitle:@"收起" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:12];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
    [close addTarget:[RRActions shared] action:@selector(closePanel)
    forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    y = 44;

    // 1) 开启录屏：系统公开的广播选择控件，点一下弹「开始直播」，不切出游戏
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, pw - pad * 2, 16)];
    l1.text = @"① 开启录屏（弹系统面板，手动确认）";
    l1.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    l1.font = [UIFont systemFontOfSize:11.5];
    [p addSubview:l1];
    y += 20;

    Class pickerCls = NSClassFromString(@"RPSystemBroadcastPickerView");
    UIView *picker = nil;
    if (pickerCls) {
        RPSystemBroadcastPickerView *bp =
            [[pickerCls alloc] initWithFrame:CGRectMake(pad, y, 44, 44)];
        bp.preferredExtension = RR_BROADCAST_EXT;
        if ([bp respondsToSelector:@selector(setShowsMicrophoneButton:)]) {
            bp.showsMicrophoneButton = NO;
        }
        picker = bp;
    }
    if (!picker) {
        // 极端情况（ReplayKit 不可用）：退化成跳转主 App 的按钮，功能不消失
        UIButton *alt = [UIButton buttonWithType:UIButtonTypeSystem];
        alt.frame = CGRectMake(pad, y, 44, 44);
        [alt setTitle:@"开" forState:UIControlStateNormal];
        [alt addTarget:[RRActions shared] action:@selector(openApp)
        forControlEvents:UIControlEventTouchUpInside];
        picker = alt;
    }
    [p addSubview:picker];

    UILabel *l1b = [[UILabel alloc] initWithFrame:CGRectMake(pad + 52, y + 4, pw - pad - 60, 36)];
    l1b.text = @"点左边按钮 → 选「回溯录制」→ 开始直播";
    l1b.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    l1b.font = [UIFont systemFontOfSize:11];
    l1b.numberOfLines = 2;
    [p addSubview:l1b];
    y += 54;

    // 2) 保存
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, pw - pad * 2, 16)];
    l2.text = @"② 保存回放";
    l2.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    l2.font = [UIFont systemFontOfSize:11.5];
    [p addSubview:l2];
    y += 20;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(pad, y, pw - pad * 2, 38);
    save.backgroundColor = [UIColor colorWithRed:0.20 green:0.72 blue:0.45 alpha:1.0];
    save.layer.cornerRadius = 9;
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [save addTarget:[RRActions shared] action:@selector(tapped)
    forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:save];
    objc_setAssociatedObject(p, "rr_save", save, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    y += 46;

    // 3) 时长档位
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 60, 16)];
    l3.text = @"③ 时长";
    l3.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    l3.font = [UIFont systemFontOfSize:11.5];
    [p addSubview:l3];
    g_segSeconds = [[UISegmentedControl alloc] initWithItems:@[@"30s", @"60s", @"120s"]];
    g_segSeconds.frame = CGRectMake(pad + 46, y - 2, pw - pad - 58, 24);
    g_segSeconds.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [g_segSeconds setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                                forState:UIControlStateSelected];
    [g_segSeconds setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                                forState:UIControlStateNormal];
    [g_segSeconds addTarget:[RRActions shared] action:@selector(secondsChanged:)
            forControlEvents:UIControlEventValueChanged];
    [p addSubview:g_segSeconds];
    y += 32;

    // 4) 码率档位
    UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 60, 16)];
    l4.text = @"④ 码率";
    l4.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    l4.font = [UIFont systemFontOfSize:11.5];
    [p addSubview:l4];
    g_segBitrate = [[UISegmentedControl alloc] initWithItems:@[@"4M", @"6M", @"8M", @"12M"]];
    g_segBitrate.frame = CGRectMake(pad + 46, y - 2, pw - pad - 58, 24);
    g_segBitrate.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [g_segBitrate setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                                forState:UIControlStateSelected];
    [g_segBitrate setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                                forState:UIControlStateNormal];
    [g_segBitrate addTarget:[RRActions shared] action:@selector(bitrateChanged:)
             forControlEvents:UIControlEventValueChanged];
    [p addSubview:g_segBitrate];
    y += 32;

    // 状态行
    g_status = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, pw - pad * 2, 28)];
    g_status.text = @"录制未开启时先在 ① 里开启";
    g_status.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    g_status.font = [UIFont systemFontOfSize:11];
    g_status.numberOfLines = 2;
    [p addSubview:g_status];
    y += 32;

    p.frame = CGRectMake(0, 0, pw, y + 8);
    g_panel = p;
    g_panel.hidden = YES;
}

static void RRRefreshPanel(void) {
    if (!g_panel) return;
    UIButton *save = objc_getAssociatedObject(g_panel, "rr_save");
    [save setTitle:[NSString stringWithFormat:@"保存最近 %ld 秒", (long)g_seconds]
          forState:UIControlStateNormal];
    NSArray *secs = @[@30, @60, @120];
    NSUInteger si = [secs indexOfObject:@(g_seconds)];
    g_segSeconds.selectedSegmentIndex = (si == NSNotFound) ? 1 : si;
    NSArray *brs = @[@4, @6, @8, @12];
    NSUInteger bi = [brs indexOfObject:@(g_bitrate)];
    g_segBitrate.selectedSegmentIndex = (bi == NSNotFound) ? 1 : bi;
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

    RRSetStatus([NSString stringWithFormat:@"已请求保存最近 %ld 秒", (long)sec]);
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
            RRSetStatus([NSString stringWithFormat:@"录制进程已收到，正在保存 %ld 秒", (long)sec]);
        } else {
            RRFallbackToApp(sec);
            RRSetStatus(@"未检测到录制进程，已切到「回溯」保存");
        }
    });
}

- (void)togglePanel {
    if (!g_panel) return;
    g_panel.hidden = !g_panel.hidden;
    if (!g_panel.hidden) {
        RRRefreshPanel();
        RRPositionPanel();
        [g_panel.superview bringSubviewToFront:g_panel];
    }
}

- (void)closePanel {
    if (g_panel) g_panel.hidden = YES;
}

- (void)openApp {
    UIApplication *app = [UIApplication sharedApplication];
    NSURL *u = [NSURL URLWithString:@"retrorecord://open"];
    if (!app) return;
    if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [app openURL:u options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [app openURL:u];
#pragma clang diagnostic pop
    }
}

- (void)secondsChanged:(UISegmentedControl *)seg {
    NSArray *secs = @[@30, @60, @120];
    if (seg.selectedSegmentIndex < (NSInteger)secs.count) {
        g_seconds = [secs[seg.selectedSegmentIndex] integerValue];
        RRSavePrefs();
        RRUpdateTitle();
        RRRefreshPanel();
    }
}

- (void)bitrateChanged:(UISegmentedControl *)seg {
    NSArray *brs = @[@4, @6, @8, @12];
    if (seg.selectedSegmentIndex < (NSInteger)brs.count) {
        g_bitrate = [brs[seg.selectedSegmentIndex] integerValue];
        RRSavePrefs();
        RRPostBitrate();     // 扩展收到后在下一段分片生效
        RRSetStatus([NSString stringWithFormat:@"码率已设为 %ld Mbps，下一段生效", (long)g_bitrate]);
    }
}

- (void)longPressed:(UILongPressGestureRecognizer *)ges {
    if (ges.state != UIGestureRecognizerStateBegan) return;
    [self tapped];   // 长按 = 立刻保存，不用展开面板
}

- (void)panned:(UIPanGestureRecognizer *)ges {
    UIView *v = ges.view;
    CGPoint t = [ges translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [ges setTranslation:CGPointZero inView:v.superview];
    RRPositionPanel();
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RRPositionPanel(); });
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
        NSInteger savedSec = [ud integerForKey:@"RetroSaveSeconds"];
        if (savedSec > 0) g_seconds = savedSec;
        NSInteger savedBr = [ud integerForKey:@"RetroSaveBitrate"];
        if (savedBr > 0) g_bitrate = savedBr;
        RRUpdateTitle();

        [g_btn addTarget:[RRActions shared] action:@selector(togglePanel)
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

    if (!g_panel) {
        RRBuildPanel();
        RRRefreshPanel();
    }

    if (g_btn.window == w && g_btn.superview == w) {
        [w bringSubviewToFront:g_btn];
        if (g_panel && g_panel.superview == w && !g_panel.hidden) {
            [w bringSubviewToFront:g_panel];
        }
        return;
    }

    [w addSubview:g_btn];              // addSubview 会自动把按钮从旧 window 摘下来
    [w bringSubviewToFront:g_btn];
    if (g_panel) {
        [w addSubview:g_panel];
        RRPositionPanel();
    }
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
