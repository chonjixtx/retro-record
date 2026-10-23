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
#define RR_RES_PREFIX @"com.retro.recorder.res."
#define RR_CFG_PREFIX @"com.retro.recorder.cfg."
#define RR_BROADCAST_EXT @"com.retro.recorder.broadcast"
#define RR_PANEL_W 224

/* 动作目标必须先声明：RRBuildPanel 在 @implementation 之前就要用到 [RRActions shared]，
   Objective-C 不允许对还没声明的类发消息（会报 Use of undeclared identifier）。 */
@interface RRActions : NSObject <UITextFieldDelegate>
+ (instancetype)shared;
- (void)tapped;
- (void)togglePanel;
- (void)closePanel;
- (void)openApp;
- (void)secondsChanged:(UISegmentedControl *)seg;
- (void)applySeconds;
- (void)bitrateChanged:(UISegmentedControl *)seg;
- (void)resChanged:(UISegmentedControl *)seg;
- (void)longPressed:(UILongPressGestureRecognizer *)ges;
- (void)panned:(UIPanGestureRecognizer *)ges;
@end

static UIButton *g_btn = nil;
static UIView *g_panel = nil;
static UILabel *g_status = nil;
static UISegmentedControl *g_segSeconds = nil;
static UISegmentedControl *g_segBitrate = nil;
static UISegmentedControl *g_segRes = nil;
static UITextField *g_secField = nil;     // ③ 自定义秒数输入框
static NSInteger g_seconds = 60;
static NSInteger g_bitrate = 6;
static NSInteger g_res = 0;   // 输出高度上限（0 = 原画质）
static BOOL g_pollInstalled = NO;

/* 手输秒数的合法区间：下限取自 fine media 的最小可导出长度，
   上限 600 秒要和 NotifyBridge.customSecondsRange 保持一致 ——
   超出这个区间的通知名扩展侧没注册，指令会石沉大海。 */
#define RR_SEC_MIN 5
#define RR_SEC_MAX 600

static NSInteger RRClampSeconds(NSInteger v) {
    if (v < RR_SEC_MIN) return RR_SEC_MIN;
    if (v > RR_SEC_MAX) return RR_SEC_MAX;
    return v;
}

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

static void RRPostRes(void) {
    RRPost([RR_RES_PREFIX stringByAppendingFormat:@"%ld", (long)g_res]);
}

/* 把当前选择的保留时长同步给扩展（面板改时长时发） */
static void RRPostCfg(void) {
    RRPost([RR_CFG_PREFIX stringByAppendingFormat:@"%ld", (long)g_seconds]);
}

/* ---------- 确认录制进程收到了没有 ---------- */

/* 扩展侧新增的一组「固定名字」回执。
   必须用固定名：iOS 的 Darwin 通知中心对 name = NULL 的通配注册经常一条都不投递，
   而 log 前缀后面跟的是自由文本（TRIG_SAVE_60 …），根本没法枚举注册 ——
   这就是之前一直误判「没在录」的根因。 */
#define RR_ACK_PREFIX  @"com.retro.recorder.ack."
#define RR_ACK_TRIG    @"com.retro.recorder.ack.trig"
#define RR_ACK_PING    @"com.retro.recorder.ack.ping"
#define RR_ACK_DONE    @"com.retro.recorder.ack.done"
#define RR_ACK_FAIL    @"com.retro.recorder.ack.fail"
#define RR_PING_PREFIX @"com.retro.recorder.ping."

static BOOL g_ackTrig = NO;   /* 扩展收到了保存指令 */
static BOOL g_ackPing = NO;   /* 扩展活着 */
static BOOL g_ackDone = NO;   /* 已写入相册 */
static BOOL g_ackFail = NO;   /* 写入失败 */
static BOOL g_ackOn = NO;
static int  g_ackToken = 0;   /* 非空 observer 句柄：CF 对 NULL observer 的处理不可靠 */

static void RRAckCallback(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (!name) return;
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:RR_ACK_TRIG])      g_ackTrig = YES;
    else if ([n isEqualToString:RR_ACK_PING]) g_ackPing = YES;
    else if ([n isEqualToString:RR_ACK_DONE]) g_ackDone = YES;
    else if ([n isEqualToString:RR_ACK_FAIL]) g_ackFail = YES;
    else if ([n hasPrefix:RR_LOG_PREFIX]) {
        /* 老协议兼容：万一通配还能用，日志里的 TRIG_SAVE 也算数 */
        NSString *body = [n substringFromIndex:[RR_LOG_PREFIX length]];
        if ([body hasPrefix:@"TRIG_SAVE"]) g_ackTrig = YES;
    }
}

/* 四个固定回执名逐个注册（保证收得到），再挂一个通配收老格式日志（可能无效，无害）。 */
static void RRAckWatchBegin(void) {
    g_ackTrig = g_ackPing = g_ackDone = g_ackFail = NO;
    if (g_ackOn) return;
    g_ackOn = YES;
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    void *obs = &g_ackToken;
    NSString *names[4] = { RR_ACK_TRIG, RR_ACK_PING, RR_ACK_DONE, RR_ACK_FAIL };
    for (int i = 0; i < 4; i++) {
        CFNotificationCenterAddObserver(c, obs, RRAckCallback,
                                        (__bridge CFStringRef)names[i], NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    CFNotificationCenterAddObserver(c, obs, RRAckCallback, NULL, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void RRAckWatchEnd(void) {
    if (!g_ackOn) return;
    g_ackOn = NO;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       &g_ackToken, NULL, NULL);
}

/* 探活：两个固定名交替，避免 notifyd 把连续两次同名通知合并 */
static void RRPostPing(void) {
    static BOOL toggle = NO;
    toggle = !toggle;
    RRPost([RR_PING_PREFIX stringByAppendingString:(toggle ? @"a" : @"b")]);
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

/* 屏幕正中央的结果提示：不切走游戏、不弹需要点「确定」的对话框。
   style: 0 = 成功（绿） 1 = 失败（黑） 2 = 警告（橙） */
static void RRCenterToast(NSString *text, NSInteger style) {
    UIWindow *w = RRKeyWindow();
    if (!w) return;
    UILabel *lb = [[UILabel alloc] init];
    lb.text = text;
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.numberOfLines = 2;
    UIColor *bg = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    if (style == 0) {
        bg = [UIColor colorWithRed:0.13 green:0.55 blue:0.33 alpha:0.92];
    } else if (style == 2) {
        bg = [UIColor colorWithRed:0.85 green:0.52 blue:0.10 alpha:0.92];
    }
    lb.backgroundColor = bg;
    lb.layer.cornerRadius = 12;
    lb.layer.masksToBounds = YES;
    lb.userInteractionEnabled = NO;
    lb.alpha = 0;
    CGFloat wd = 240, ht = 62;
    lb.frame = CGRectMake((w.bounds.size.width - wd) / 2,
                          (w.bounds.size.height - ht) / 2, wd, ht);
    [w addSubview:lb];
    [w bringSubviewToFront:lb];
    [UIView animateWithDuration:0.16 animations:^{ lb.alpha = 1; } completion:^(BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ lb.alpha = 0; } completion:^(BOOL f2) {
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
    [ud setInteger:g_res forKey:@"RetroSaveRes"];
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

/* 数字键盘没有换行键，在输入框上方挂一条「应用秒数」，输完直接点就行 */
static UIView *RRFieldToolbar(void) {
    UIToolbar *tb = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 240, 36)];
    tb.tintColor = [UIColor systemBlueColor];
    UIBarButtonItem *flex =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                     target:nil action:nil];
    UIBarButtonItem *done =
        [[UIBarButtonItem alloc] initWithTitle:@"应用秒数"
                                         style:UIBarButtonItemStyleDone
                                        target:[RRActions shared]
                                        action:@selector(applySeconds)];
    tb.items = @[flex, done];
    return tb;
}

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

    // 3b) 自定义秒数：直接输数字，面板宽只有 224 所以排一行「标签 + 输入框 + 应用」
    UILabel *l3b = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 48, 26)];
    l3b.text = @"自定义";
    l3b.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    l3b.font = [UIFont systemFontOfSize:11];
    [p addSubview:l3b];

    g_secField = [[UITextField alloc] initWithFrame:CGRectMake(pad + 50, y, 62, 26)];
    g_secField.keyboardType = UIKeyboardTypeNumberPad;
    g_secField.borderStyle = UITextBorderStyleNone;
    g_secField.layer.cornerRadius = 6;
    g_secField.layer.borderWidth = 1;
    g_secField.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    g_secField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    g_secField.textColor = [UIColor whiteColor];
    g_secField.font = [UIFont systemFontOfSize:13];
    g_secField.textAlignment = NSTextAlignmentCenter;
    g_secField.clearButtonMode = UITextFieldViewModeWhileEditing;
    g_secField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"5-600"
                                        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    g_secField.delegate = [RRActions shared];
    g_secField.inputAccessoryView = RRFieldToolbar();
    [p addSubview:g_secField];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(pw - pad - 66, y, 66, 26);
    apply.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    apply.layer.cornerRadius = 6;
    [apply setTitle:@"应用" forState:UIControlStateNormal];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [apply addTarget:[RRActions shared] action:@selector(applySeconds)
    forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:apply];
    y += 34;

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

    // 5) 画质档位（输出分辨率上限，只向下缩；原生 = 跟随系统给的帧）
    UILabel *l5 = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 60, 16)];
    l5.text = @"⑤ 画质";
    l5.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    l5.font = [UIFont systemFontOfSize:11.5];
    [p addSubview:l5];
    g_segRes = [[UISegmentedControl alloc] initWithItems:@[@"1080p", @"2K", @"4K", @"原生"]];
    g_segRes.frame = CGRectMake(pad + 46, y - 2, pw - pad - 58, 24);
    g_segRes.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [g_segRes setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                           forState:UIControlStateSelected];
    [g_segRes setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                           forState:UIControlStateNormal];
    [g_segRes addTarget:[RRActions shared] action:@selector(resChanged:)
          forControlEvents:UIControlEventValueChanged];
    [p addSubview:g_segRes];
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
    // 自定义值不属于任何快捷档位：不要默默高亮某一个，直接取消选中，避免误导
    g_segSeconds.selectedSegmentIndex = (si == NSNotFound) ? UISegmentedControlNoSegment : si;
    if (g_secField && !g_secField.isFirstResponder) {
        g_secField.text = [NSString stringWithFormat:@"%ld", (long)g_seconds];
    }
    NSArray *brs = @[@4, @6, @8, @12];
    NSUInteger bi = [brs indexOfObject:@(g_bitrate)];
    g_segBitrate.selectedSegmentIndex = (bi == NSNotFound) ? 1 : bi;
    NSArray *resVals = @[@1080, @1440, @2160, @0];
    NSUInteger ri = [resVals indexOfObject:@(g_res)];
    g_segRes.selectedSegmentIndex = (ri == NSNotFound) ? 3 : ri;
}

/* ---------- 动作目标 ---------- */

@implementation RRActions

+ (instancetype)shared {
    static RRActions *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RRActions new]; });
    return s;
}

- (void)tapped {
    NSInteger sec = g_seconds;

    // 先探活再下指令，这样 3 秒后能区分「扩展不在」和「扩展在但指令没送到」
    RRAckWatchBegin();
    RRPostPing();
    // 连发三次（0 / 0.25 / 0.5 秒）：单条 Darwin 通知偶发丢失时后面两次还能补上
    RRPostTrigger();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPostTrigger(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPostTrigger(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPostPing(); });

    [UIView animateWithDuration:0.09 animations:^{
        g_btn.transform = CGAffineTransformMakeScale(1.18, 1.18);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.09 animations:^{ g_btn.transform = CGAffineTransformIdentity; }];
    }];

    // 不再跳转到主 App：跳走会打断游戏，用户要的是「点了就地给个结果」。
    // 1.8 秒后按回执在屏幕中间显示结论：收到回执 = 已保存；没收到 = 提示没在录。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL trig = g_ackTrig, ping = g_ackPing, done = g_ackDone, fail = g_ackFail;
        RRAckWatchEnd();
        if (done || trig) {
            RRCenterToast([NSString stringWithFormat:@"已保存\n最近 %ld 秒", (long)sec], 0);
        } else if (fail) {
            RRCenterToast(@"保存失败\n去相册权限看看", 1);
        } else if (ping) {
            RRCenterToast(@"扩展在，指令没送到\n重开一次录屏", 2);
        } else {
            RRCenterToast(@"扩展已不在\n在面板①重新开录屏", 1);
        }
    });
}

- (void)togglePanel {
    if (!g_panel) return;
    if (g_panel.hidden) {
        g_panel.hidden = NO;
        RRRefreshPanel();
        RRPositionPanel();
        [g_panel.superview bringSubviewToFront:g_panel];
    } else {
        [g_secField resignFirstResponder];
        g_panel.hidden = YES;
    }
}

- (void)closePanel {
    [g_secField resignFirstResponder];
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
        // 同步给录制扩展：保留窗口必须盖住这个时长，否则选 60 秒时
        // 落盘只有 50 秒左右的料，导出的视频会短一截
        RRPostCfg();
    }
}

/* ③ 自定义秒数：读输入框内容，夹到合法区间后立刻生效并同步给扩展。
   超出区间不静默处理 —— 告诉用户被夹成了多少，避免「我输 900 结果存了 600」的困惑。 */
- (void)applySeconds {
    if (!g_secField) return;
    NSString *raw = [g_secField.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [g_secField resignFirstResponder];

    if (raw.length == 0) {
        g_secField.text = [NSString stringWithFormat:@"%ld", (long)g_seconds];
        return;
    }
    NSInteger v = [raw integerValue];
    if (v <= 0) {
        RRToast(@"秒数得是大于 0 的整数");
        g_secField.text = [NSString stringWithFormat:@"%ld", (long)g_seconds];
        return;
    }

    NSInteger clamped = RRClampSeconds(v);
    g_seconds = clamped;
    g_secField.text = [NSString stringWithFormat:@"%ld", (long)clamped];
    if (clamped != v) {
        RRToast([NSString stringWithFormat:@"可选 %d-%d 秒，已按 %ld 秒保存",
                 RR_SEC_MIN, RR_SEC_MAX, (long)clamped]);
    }
    RRSavePrefs();
    RRUpdateTitle();
    RRRefreshPanel();
    // 保留窗口必须盖住这个时长，否则标称 300 秒、扩展手里只有 60 秒的量。
    // cfg 通道只按 App 的固定档位注册，手输值大概率送不到；真正确保窗口够用的是
    // 扩展收到 trigger 时按需抬窗口（SampleHandler 里的 RET_UP_ 分支）。
    RRPostCfg();
}

#pragma mark - UITextFieldDelegate

/* 键盘弹起来会盖住面板下半截，面板在屏幕中下部时整体上移，结束后复位 */
- (void)textFieldDidBeginEditing:(UITextField *)tf {
    if (!g_panel) return;
    CGFloat shift = (CGRectGetMinY(g_panel.frame) > 150) ? -120.0 : 0.0;
    [UIView animateWithDuration:0.22 animations:^{
        g_panel.transform = CGAffineTransformMakeTranslation(0, shift);
    }];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (!g_panel) return;
    [UIView animateWithDuration:0.22 animations:^{
        g_panel.transform = CGAffineTransformIdentity;
    }];
}

- (BOOL)textField:(UITextField *)tf
    shouldChangeCharactersInRange:(NSRange)range
    replacementString:(NSString *)string {
    // 只收数字；再把长度卡在 3 位（上限 600），省得用户输完才发现超范围。
    // 粘贴的场景也走这里，一串非数字会被直接拒绝。
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 0; i < string.length; i++) {
        if (![digits characterIsMember:[string characterAtIndex:i]]) return NO;
    }
    NSString *next = [tf.text stringByReplacingCharactersInRange:range withString:string];
    return next.length <= 3;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self applySeconds];
    return YES;
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

- (void)resChanged:(UISegmentedControl *)seg {
    NSArray *vals = @[@1080, @1440, @2160, @0];
    if (seg.selectedSegmentIndex < (NSInteger)vals.count) {
        g_res = [vals[seg.selectedSegmentIndex] integerValue];
        RRSavePrefs();
        RRPostRes();         // 扩展收到后立刻切一段新分片生效
        RRSetStatus(g_res == 0 ? @"画质：原画质（跟随系统）"
                               : [NSString stringWithFormat:@"画质上限 %ldp，下一段生效（只能向下缩）", (long)g_res]);
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
        // 老版本可能存过超出区间的值（比如 App 里给的 900），读回来先夹一下，
        // 否则发出去的通知名扩展没注册，点保存不会有任何反应
        if (savedSec > 0) g_seconds = RRClampSeconds(savedSec);
        NSInteger savedBr = [ud integerForKey:@"RetroSaveBitrate"];
        if (savedBr > 0) g_bitrate = savedBr;
        NSInteger savedRes = [ud integerForKey:@"RetroSaveRes"];
        if (savedRes >= 0 && [ud objectForKey:@"RetroSaveRes"] != nil) g_res = savedRes;
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
        // 面板首次挂载时把手上的时长/码率/画质同步给扩展一次：
        // 面板的值存在游戏进程的 NSUserDefaults，扩展的配置在共享目录，两者可能不同步
        static BOOL g_synced = NO;
        if (!g_synced) {
            g_synced = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                RRPostBitrate();
                RRPostRes();
                RRPostCfg();
            });
        }
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
