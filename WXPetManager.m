#import "WXPetManager.h"
#import "WXPCommon.h"
#import "WXPFrontmost.h"
#import "WXPetWindow.h"
#import "WXPetView.h"
#import <math.h>

@interface WXPetManager () <WXPetViewDelegate>
@end

@implementation WXPetManager {
    WXPetWindow *_window;
    dispatch_source_t _timer;
    NSString *_frontmost;         // 当前前台 App 的 bundle id（nil = 判定失败）
    double _lastScreenW;
    double _lastScreenH;
    NSInteger _attachRetry;       // 挂 scene 的重试次数
    BOOL _started;
}

+ (instancetype)shared {
    static WXPetManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[WXPetManager alloc] init]; });
    return instance;
}

#pragma mark - 生命周期

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    if (_started) {
        // 第二次调用（通常是 SpringBoard applicationDidFinishLaunching 兜底）
        [self reloadPrefs];
        return;
    }
    _started = YES;
    WXPProbeLog(@"[管理器] start 版本 %@", WXP_VERSION);

    __weak typeof(self) weakSelf = self;
    WXPWatchPrefsChanged(^{
        WXPetManager *me = weakSelf;
        if (me) [me reloadPrefs];
    });

    [self buildWindow];
    [self startPolling];
    [self tick];
}

- (void)buildWindow {
    if (_window) return;

    _window = [[WXPetWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.alpha = 0.0;

    WXPetView *pet = [[WXPetView alloc] initWithFrame:CGRectMake(0, 0, 120, 120)];
    pet.delegate = self;
    [_window.rootViewController.view addSubview:pet];
    _window.petView = pet;

    BOOL attached = [_window attachToScene];
    WXPProbeLog(@"[窗口] 已创建：scene=%@ 层级=%.0f 尺寸=%@",
                attached ? @"已挂" : @"未挂(会重试)",
                _window.windowLevel,
                NSStringFromCGRect(_window.frame));

    // 先保持隐藏，等 tick 判定完再决定是否显示 —— 避免启动瞬间闪一下
    _window.hidden = YES;
    [self layoutPet];
}

- (void)startPolling {
    if (_timer) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t interval = (uint64_t)(0.35 * (double)NSEC_PER_SEC);
    // leeway 给 80ms：省电，且前台判定本来就不需要精确到毫秒
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, (uint64_t)(0.08 * (double)NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        WXPetManager *me = weakSelf;
        if (me) [me tick];
    });
    dispatch_resume(_timer);
}

#pragma mark - 每次轮询

- (void)tick {
    if (!_window) [self buildWindow];

    // ── 前台 App ──
    NSString *fg = WXPFrontmostBundleID();
    BOOL changed = NO;
    if (fg == nil && _frontmost != nil) changed = YES;
    else if (fg != nil && ![fg isEqualToString:_frontmost]) changed = YES;
    if (changed) {
        _frontmost = fg;
        WXPProbeLog(@"[前台] → %@", fg ?: @"(判定失败)");
    }

    // ── 屏幕尺寸变化（旋转/横屏）→ 重排 ──
    CGRect screen = [UIScreen mainScreen].bounds;
    if (fabs(screen.size.width - _lastScreenW) > 0.5 ||
        fabs(screen.size.height - _lastScreenH) > 0.5) {
        _lastScreenW = screen.size.width;
        _lastScreenH = screen.size.height;
        _window.frame = screen;
        _window.rootViewController.view.frame = screen;
        [self layoutPet];
        WXPProbeLog(@"[布局] 屏幕变为 %@", NSStringFromCGRect(screen));
    }

    // ── scene 掉线自愈（SpringBoard 早期可能还没有 scene）──
    if (!_window.windowScene) {
        if (_attachRetry < 90) {          // 约 31 秒
            _attachRetry++;
            [_window attachToScene];
            if (_attachRetry == 90) {
                WXPProbeLog(@"[窗口] ⚠️ 重试 90 次仍取不到窗口场景 —— 宠物不会显示。"
                             "请把探针发我（[侦查] 行里的 connectedScenes 是空的吗？）");
            }
        }
    }

    [self applyState];
}

#pragma mark - 显示判定

- (BOOL)shouldShow {
    if (!WXPEnabled()) return NO;

    NSInteger mode = WXPShareModeValue();
    if (mode == WXPShareModeAll) return YES;   // 所有 App 都显示

    NSString *fg = _frontmost;
    if (!fg.length) {
        // ⭐ 判定失败时 **默认不显示**（fail-closed）。
        //   为什么不做 fail-open：那会让「仅限微信」静默失效 ——
        //   用户会看到宠物到处都出现，却查不出是判定失败。
        //   想临时确认「宠物本身能不能显示」，打开设置里的
        //   「前台判定失败时也显示（调试）」即可。
        return WXPAlwaysShow();
    }

    BOOL inList = [WXPAppIDs() containsObject:fg];
    return (mode == WXPShareModeBlacklist) ? !inList : inList;
}

- (void)applyState {
    if (!_window) return;
    BOOL should  = [self shouldShow];
    BOOL visible = !_window.hidden;
    if (should == visible) return;

    _window.hidden = !should;
    if (should) {
        _window.alpha = 0.0;
        [UIView animateWithDuration:0.20 animations:^{ self->_window.alpha = 1.0; }];
        WXPProbeLog(@"[显示] 宠物出现（前台 %@）", _frontmost ?: @"(未判定)");
    } else {
        _window.alpha = 0.0;
    }
}

#pragma mark - 布局

- (void)layoutPet {
    if (!_window || !_window.petView) return;
    CGRect b = _window.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return;

    // 宠物基准边长 = 短边 × 0.24（iPhone 上约 96pt），再乘用户缩放
    CGFloat base = MIN(b.size.width, b.size.height) * 0.24;
    CGFloat size = MAX(48.0, base * (CGFloat)WXPPetScale());

    WXPetView *pet = _window.petView;
    pet.bounds = CGRectMake(0, 0, size, size);

    CGFloat x = b.size.width  * (CGFloat)WXPPetPosX();
    CGFloat y = b.size.height * (CGFloat)WXPPetPosY();
    // 夹住，保证宠物完整可见（顶部留 34pt 避开刘海/状态栏）
    x = MAX(size / 2.0 + 2.0,  MIN(b.size.width  - size / 2.0 - 2.0, x));
    y = MAX(size / 2.0 + 34.0, MIN(b.size.height - size / 2.0 - 6.0, y));
    pet.center = CGPointMake(x, y);
    pet.alpha  = (CGFloat)WXPPetAlpha();

    pet.draggable = WXPDraggable();
    pet.snapEdge  = WXPSnapEdge();
}

#pragma mark - 配置

- (void)reloadPrefs {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadPrefs]; });
        return;
    }
    WXPProbeLog(@"[配置] 重新加载：启用=%d 模式=%ld 白名单=%lu 个 缩放=%.2f",
                (int)WXPEnabled(),
                (long)WXPShareModeValue(),
                (unsigned long)WXPAppIDs().count,
                WXPPetScale());
    [self layoutPet];
    [self applyState];
}

#pragma mark - WXPetViewDelegate

- (void)petViewDidFinishDrag:(WXPetView *)pet {
    CGRect b = _window.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return;
    // 存归一化坐标（0~1）—— 换机型/转屏都不会跑偏
    WXPSetPetPosition((double)(pet.center.x / b.size.width),
                      (double)(pet.center.y / b.size.height));
}

@end
