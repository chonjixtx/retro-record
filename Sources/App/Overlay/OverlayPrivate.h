//  全局悬浮窗（TrollStore 专用）需要的私有接口声明。
//
//  这些类只存在于设备私有框架里（FrontBoard / FrontBoardServices / UIKit 私有部分），
//  SDK 里没有声明，这里自己声明后即可直接调用（ObjC 方法调用是运行时动态分发）。
//  调用前都会 dlopen 对应框架 + NSClassFromString 判空 + @try/@catch 兜底，
//  系统版本差异导致接口缺失时不会崩溃，只是悬浮窗不可用。
#import <UIKit/UIKit.h>

// MARK: - FrontBoard

@interface FBSceneManager : NSObject
+ (instancetype)sharedInstance;
- (id)createSceneWithDefinition:(id)definition initialParameters:(id)parameters;
@end

@interface FBSMutableSceneDefinition : NSObject
@property (nonatomic, copy) id clientIdentity;
@property (nonatomic, copy) id identity;
@property (nonatomic, copy) id specification;
+ (instancetype)definition;
@end

@interface FBSSceneIdentity : NSObject
+ (instancetype)identityForIdentifier:(NSString *)identifier;
@end

@interface FBSSceneClientIdentity : NSObject
+ (instancetype)localIdentity;
@end

@interface FBSSceneSpecification : NSObject
+ (instancetype)specification;
@end

@interface UIApplicationSceneSpecification : FBSSceneSpecification
@end

@interface FBSMutableSceneParameters : NSObject
@property (nonatomic, copy) id settings;
@property (nonatomic, copy) id clientSettings;
+ (instancetype)parametersForSpecification:(FBSSceneSpecification *)specification;
@end

@interface UIMutableApplicationSceneSettings : NSObject
- (id)displayConfiguration;
- (CGRect)frame;
- (NSMutableSet *)ignoreOcclusionReasons;
- (void)setDisplayConfiguration:(id)configuration;
- (void)setForeground:(BOOL)foreground;
- (void)setFrame:(CGRect)frame;
- (void)setLevel:(NSInteger)level;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)setDeviceOrientationEventsEnabled:(BOOL)enabled;
@end

@interface UIMutableApplicationSceneClientSettings : NSObject
@property (nonatomic, assign) NSInteger interfaceOrientation;
@property (nonatomic, assign) NSInteger statusBarStyle;
@end

@interface UIRootWindowScenePresentationBinder : NSObject
- (instancetype)initWithPriority:(int)priority displayConfiguration:(id)displayConfiguration;
- (void)addScene:(id)scene;
@end

@interface FBSOrientationObserver : NSObject
- (void)invalidate;
- (void)setHandler:(id)handler;
@end

@interface FBSOrientationUpdate : NSObject
- (long long)orientation;
- (double)duration;
@end

// MARK: - UIKit 私有

@interface UIWindow (RetroOverlayPrivate)
- (void)_rotateWindowToOrientation:(long long)orientation
                  updateStatusBar:(BOOL)updateStatusBar
                          duration:(double)duration
                    skipCallbacks:(BOOL)skipCallbacks;
@end

@interface UIScreen (RetroOverlayPrivate)
- (CGRect)_referenceBounds;
- (id)displayConfiguration;
@end
