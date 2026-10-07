#import "WXPetWindow.h"
#import "WXPCommon.h"

// 挑一个可用的窗口场景。
// 优先级：前台活跃的 → 第一个 UIWindowScene → 借已有窗口的 scene。
// 最后那条兜底很关键：SpringBoard 起来早期 connectedScenes 可能还是空的，
// 但此时已经有系统窗口存在，直接借它的 scene 一样能用。
static UIWindowScene *WXPBestWindowScene(void) {
    UIWindowScene *first = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (!first) first = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    if (first) return first;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene) return w.windowScene;
    }
    return nil;
}

@implementation WXPetWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.windowLevel = WXP_WINDOW_LEVEL;   // 高于 App 窗口，低于系统临时面板
        self.autoresizesSubviews = YES;

        // 必须有个 rootViewController：iOS 13+ 没有根控制器的窗口布局会不正常
        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.frame = self.bounds;
        root.view.userInteractionEnabled = YES;
        self.rootViewController = root;

        // ⚠️⚠️ 这里**故意不调用 makeKeyAndVisible**。
        //   血泪（DecoyLock v0.2.x 锁屏卡死事故）：自建高层级窗口抢走系统
        //   key window 后，退出时只 hidden=YES 而没把 key 还回去 →
        //   用户「看得见界面但点不动」。
        //   本插件只做装饰，不接管任何输入焦点，所以连 key 都不碰。
        self.hidden = YES;
    }
    return self;
}

- (BOOL)attachToScene {
    if (!self.windowScene) {
        UIWindowScene *best = WXPBestWindowScene();
        if (best) {
            self.windowScene = best;
            WXPProbeLog(@"[窗口] 已挂到场景 %@ (state=%ld)",
                        NSStringFromClass(object_getClass(best)), (long)best.activationState);
        }
    }
    return self.windowScene != nil;
}

// ⭐ 触摸放行：只有落在宠物本体（含少量外扩）上才吃这次触摸，
//    其它位置一律返回 nil —— UIKit 会把触摸交给下层窗口，也就是 App。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.02) return nil;

    WXPetView *pet = self.petView;
    if (!pet) return nil;

    CGPoint p = [pet convertPoint:point fromView:self];
    CGRect hit = CGRectInset(pet.bounds, -WXP_HIT_SLOP, -WXP_HIT_SLOP);
    if (!CGRectContainsPoint(hit, p)) return nil;

    return [super hitTest:point withEvent:event];
}

@end
