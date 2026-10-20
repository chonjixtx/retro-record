/*
 * RetroSaveInGame —— 在游戏进程内绘制悬浮按钮，点击触发回溯保存。
 *
 * 工作方式：只往游戏当前的 keyWindow 上加一颗按钮，点击时通过 Darwin 通知
 * （CFNotificationCenter）把指令发给正在录制的回溯扩展进程，游戏不会被切走。
 * 不 hook 任何游戏方法、不读写游戏内存、不修改游戏任何逻辑与数据。
 *
 * 交互：单击 = 保存最近 N 秒；长按 0.8s = 在 30/60/120 秒之间切档；拖动 = 挪位置。
 */

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>

#define RR_BTN_SIZE 58

static UIButton *g_btn = nil;
static NSInteger g_seconds = 60;
static NSArray<NSNumber *> *g_options;

/* ---------- 指令发送 ---------- */

static void RRPostTrigger(void) {
    NSString *name = [NSString stringWithFormat:@"com.retro.recorder.trigger.%ld", (long)g_seconds];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name, NULL, NULL, YES);
}

/* ---------- 界面辅助 ---------- */

static UIWindow *RRKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.keyWindow) return app.keyWindow;
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
    lb.alpha = 0;
    CGFloat wd = 160, ht = 36;
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
    RRPostTrigger();
    RRToast([NSString stringWithFormat:@"已保存最近 %ld 秒", (long)g_seconds]);
    [UIView animateWithDuration:0.09 animations:^{
        g_btn.transform = CGAffineTransformMakeScale(1.18, 1.18);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.09 animations:^{ g_btn.transform = CGAffineTransformIdentity; }];
    }];
}

- (void)longPressed:(UILongPressGestureRecognizer *)ges {
    if (ges.state != UIGestureRecognizerStateBegan) return;
    NSUInteger idx = [g_options indexOfObject:@(g_seconds)];
    if (idx == NSNotFound) idx = 0;
    g_seconds = [g_options[(idx + 1) % g_options.count] integerValue];
    [[NSUserDefaults standardUserDefaults] setInteger:g_seconds forKey:@"RetroSaveSeconds"];
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
    }
}

@end

/* ---------- 挂载 ---------- */

static void RRAttach(UIWindow *w) {
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
    // addSubview 会自动把按钮从旧 window 上摘下来，换窗口不会丢
    [w addSubview:g_btn];
    [w bringSubviewToFront:g_btn];
}

%ctor {
    g_options = @[@30, @60, @120];
    @autoreleasepool {
        // 游戏启动时 keyWindow 还没就绪：延迟挂一次；之后每次 keyWindow 变化再重挂
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            RRAttach(RRKeyWindow());
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RRAttach(RRKeyWindow());
        });
    }
}
