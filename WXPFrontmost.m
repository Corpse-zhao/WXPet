#import "WXPFrontmost.h"
#import "WXPCommon.h"
#import <stdlib.h>
#import <string.h>

// ═══════════════════════════════════════════════════════════════════════════
//  为什么要「候选链 + 运行时侦查」，而不是直接写一个类名就完事
//
//  血泪（DecoyLock v0.2.0~v0.2.5 连错五轮）：把私有类名/方法名钉死在代码里，
//  真机上方法根本不存在 → Logos / objc_msgSend 静默失败 → 功能一次都没生效，
//  而日志里全是「已暂停生物识别匹配」这种**假成功**，把排查带偏三轮。
//
//  本文件的做法：
//    ① 不钉死任何单一入口 —— 列出 10 条候选，谁先命中就用谁；
//    ② 每次调用前用 method_copyReturnType **校验返回类型**，
//       确认真的返回对象才敢 objc_msgSend（防「把 BOOL 方法当对象方法调」崩进程）；
//    ③ 命中/失败都写探针，并把「是哪条候选命中的」一起写下来。
//  这样即使你机器上一条都命中不了，下一轮我照着日志补一条就行 —— 不用再猜。
// ═══════════════════════════════════════════════════════════════════════════

#pragma mark - 受保护的消息发送

// 取方法的返回类型编码（调用方负责 free）。
// 用 object_getClass 而不是 [obj class]：
//   · obj 是实例 → object_getClass = 它的类 → 查实例方法 ✓
//   · obj 是 Class（类对象）→ object_getClass = 元类 → 查**类方法** ✓
//   （这正是 DecoyLock v0.2.2 那条教训：查表用 [self class] 会拿到假类名）
static char *WXPReturnType(id obj, SEL sel) {
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) m = class_getInstanceMethod([obj class], sel);
    if (!m) return NULL;
    return method_copyReturnType(m);
}

// 只有「确实返回对象」才认为可安全转发（'@?' 是 block，不是我们要的普通对象）
static BOOL WXPSelectorReturnsObject(id obj, SEL sel) {
    char *rt = WXPReturnType(obj, sel);
    if (!rt) return NO;
    BOOL ok = (rt[0] == '@' && rt[1] != '?');
    free(rt);
    return ok;
}

static BOOL WXPSelectorReturnsBool(id obj, SEL sel) {
    char *rt = WXPReturnType(obj, sel);
    if (!rt) return NO;
    BOOL ok = (rt[0] == 'B' || rt[0] == 'c');
    free(rt);
    return ok;
}

// 给「实例或类对象」发一个返回对象的消息（不满足条件就返回 nil，绝不硬发）
static id WXPSendObject(id target, NSString *name) {
    if (!target || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![target respondsToSelector:sel]) return nil;
    if (!WXPSelectorReturnsObject(target, sel)) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

// 给类对象发类方法
static id WXPSendClassObject(Class cls, NSString *name) {
    if (!cls) return nil;
    return WXPSendObject((id)cls, name);
}

static BOOL WXPSendBool(id target, NSString *name) {
    if (!target || !name.length) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![target respondsToSelector:sel]) return NO;
    if (!WXPSelectorReturnsBool(target, sel)) return NO;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

static NSString *WXPStringFromAny(id v) {
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
    return nil;
}

static BOOL WXPStringLooksLikeBundleID(NSString *s) {
    if (!s.length) return NO;
    if ([s rangeOfString:@"."].location == NSNotFound) return NO;
    return YES;
}

#pragma mark - 从任意对象上「钻」出 bundle id

static NSArray<NSString *> *WXPBundleKeys(void) {
    // 不同 iOS 版本/不同类上叫法不同，全试一遍
    return @[@"bundleIdentifier",
             @"displayIdentifier",
             @"applicationIdentifier",
             @"bundleID"];
}

static NSArray<NSString *> *WXPDrillKeys(void) {
    // 拿到的可能不是 App 对象，而是「句柄/布局状态」，往下钻一层
    return @[@"application",
             @"sceneHandle",
             @"applicationSceneHandle",
             @"workspaceEntity",
             @"frontmostApplication",
             @"_frontmostApplication",
             @"frontmostApplicationSceneHandle",
             @"_frontmostApplicationSceneHandle",
             @"currentLayoutState",
             @"layoutState",
             @"_layoutState"];
}

// 递归（深度受限）从一个对象里取出 bundle id
static NSString *WXPBundleIDFromAny(id obj, int depth) {
    if (!obj || depth <= 0) return nil;

    // 已经是字符串 → 校验一下像不像 bundle id 再收
    NSString *direct = WXPStringFromAny(obj);
    if (direct) return WXPStringLooksLikeBundleID(direct) ? direct : nil;

    // ① 自己身上有没有 bundle id 字段
    for (NSString *k in WXPBundleKeys()) {
        NSString *v = WXPStringFromAny(WXPSendObject(obj, k));
        if (v) return v;
    }

    // ② 往下钻一层
    for (NSString *k in WXPDrillKeys()) {
        id sub = WXPSendObject(obj, k);
        if (!sub || sub == obj) continue;
        NSString *v = WXPBundleIDFromAny(sub, depth - 1);
        if (v) return v;
    }

    return nil;
}

#pragma mark - 候选链

// 候选 6：SBApplicationController → runningApplications → 找 isFrontmost 的那个
static NSString *WXPTryApplicationController(NSString **outPath) {
    Class ac = objc_getClass("SBApplicationController");
    if (!ac) return nil;
    id shared = WXPSendClassObject(ac, @"sharedInstance");
    if (!shared) return nil;

    id running = WXPSendObject(shared, @"runningApplications");
    if (!running) return nil;
    if (![running isKindOfClass:[NSSet class]] && ![running isKindOfClass:[NSArray class]]) return nil;

    for (id app in (id)running) {
        BOOL front = WXPSendBool(app, @"isFrontmost")
                  || WXPSendBool(app, @"_isFrontmost")
                  || WXPSendBool(app, @"isFrontmostApplication");
        if (!front) continue;
        NSString *b = WXPBundleIDFromAny(app, 1);
        if (b.length) {
            if (outPath) *outPath = @"SBApplicationController.isFrontmost";
            return b;
        }
    }
    return nil;
}

// 候选 7~：SBSceneManagerCoordinator → mainDisplaySceneManager → 场景句柄/布局状态
static NSString *WXPTrySceneManager(NSString **outPath) {
    Class coord = objc_getClass("SBSceneManagerCoordinator");
    if (!coord) return nil;
    id shared = WXPSendClassObject(coord, @"sharedInstance");
    if (!shared) return nil;

    static NSString *const mgrKeys[] = {@"mainDisplaySceneManager", @"_mainDisplaySceneManager", @"mainSceneManager"};
    id mgr = nil;
    for (size_t i = 0; i < sizeof(mgrKeys) / sizeof(mgrKeys[0]); i++) {
        mgr = WXPSendObject(shared, mgrKeys[i]);
        if (mgr) break;
    }
    if (!mgr) return nil;

    static NSString *const handleKeys[] = {@"_frontmostApplicationSceneHandle",
                                           @"frontmostApplicationSceneHandle",
                                           @"currentLayoutState",
                                           @"layoutState",
                                           @"_layoutState"};
    static NSString *const handleNames[] = {@"SceneMgr._frontmostApplicationSceneHandle",
                                            @"SceneMgr.frontmostApplicationSceneHandle",
                                            @"SceneMgr.currentLayoutState",
                                            @"SceneMgr.layoutState",
                                            @"SceneMgr._layoutState"};
    for (size_t i = 0; i < sizeof(handleKeys) / sizeof(handleKeys[0]); i++) {
        id h = WXPSendObject(mgr, handleKeys[i]);
        if (!h) continue;
        NSString *b = WXPBundleIDFromAny(h, 3);
        if (b.length) {
            if (outPath) *outPath = handleNames[i];
            return b;
        }
    }
    return nil;
}

// 整条链跑一次；outPath 回填「是哪条候选命中的」，用于日志
static NSString *WXPFrontmostOnce(NSString **outPath) {
    id sb = [UIApplication sharedApplication];   // SpringBoard 继承自 UIApplication
    NSString *b = nil;

    // ── 候选 1~3：SpringBoard 上的直接取值（返回 SBApplication 对象）──
    b = WXPBundleIDFromAny(WXPSendObject(sb, @"_frontMostApplication"), 2);
    if (b.length) { if (outPath) *outPath = @"SB._frontMostApplication"; return b; }

    b = WXPBundleIDFromAny(WXPSendObject(sb, @"_accessibilityFrontMostApplication"), 2);
    if (b.length) { if (outPath) *outPath = @"SB._accessibilityFrontMostApplication"; return b; }

    b = WXPBundleIDFromAny(WXPSendObject(sb, @"frontmostApplication"), 2);
    if (b.length) { if (outPath) *outPath = @"SB.frontmostApplication"; return b; }

    // ── 候选 4~5：直接返回字符串 ──
    b = WXPStringFromAny(WXPSendObject(sb, @"_frontMostAppBundleIdentifier"));
    if (b.length) { if (outPath) *outPath = @"SB._frontMostAppBundleIdentifier"; return b; }

    b = WXPStringFromAny(WXPSendObject(sb, @"_frontmostApplicationBundleIdentifier"));
    if (b.length) { if (outPath) *outPath = @"SB._frontmostApplicationBundleIdentifier"; return b; }

    // ── 候选 6：App 控制器 ──
    b = WXPTryApplicationController(outPath);
    if (b.length) return b;

    // ── 候选 7~：场景管理器 ──
    b = WXPTrySceneManager(outPath);
    if (b.length) return b;

    return nil;
}

#pragma mark - 对外接口

static NSString *gWXPHitPath = nil;      // 上次命中的候选名（只用于日志去重）
static BOOL gWXPFailLogged = NO;         // 「全部失败」只喊一次，不刷屏

NSString *WXPFrontmostBundleID(void) {
    NSString *path = nil;
    NSString *b = WXPFrontmostOnce(&path);

    if (b.length) {
        if (![gWXPHitPath isEqualToString:path]) {
            gWXPHitPath = path;
            WXPProbeLog(@"[前台] 判定链命中：%@", path);
        }
        return b;
    }

    if (!gWXPFailLogged) {
        gWXPFailLogged = YES;
        WXPProbeLog(@"[前台] ⚠️ 全部候选判定失败 —— 宠物不会显示。");
        WXPProbeLog(@"[前台]    处理：① 打开设置里的「前台判定失败时也显示」临时确认宠物能显示；"
                     "② 把探针发我，我照着 [侦查] 行补候选。");
    }
    return nil;
}

#pragma mark - 侦查

static NSString *WXPListRespondingSelectors(id obj, NSArray<NSString *> *names) {
    NSMutableArray<NSString *> *yes = [NSMutableArray array];
    for (NSString *n in names) {
        if ([obj respondsToSelector:NSSelectorFromString(n)]) [yes addObject:n];
    }
    return yes.count ? [yes componentsJoinedByString:@", "] : @"(无)";
}

void WXPFrontmostRecon(void) {
    id sb = [UIApplication sharedApplication];
    WXPProbeLog(@"[侦查] UIApplication 实例类 = %@",
                NSStringFromClass(object_getClass(sb)));

    NSArray<NSString *> *sbSels = @[@"_frontMostApplication",
                                    @"_accessibilityFrontMostApplication",
                                    @"frontmostApplication",
                                    @"_frontMostAppBundleIdentifier",
                                    @"_frontmostApplicationBundleIdentifier",
                                    @"_frontMostApplicationDisplayIdentifier"];
    WXPProbeLog(@"[侦查] SpringBoard 响应的候选方法：%@",
                WXPListRespondingSelectors(sb, sbSels));

    // 场景：决定我们的悬浮窗能挂到哪个 scene 上（iOS 13+ 不挂 scene 就不显示）
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    NSMutableArray<NSString *> *sceneDesc = [NSMutableArray array];
    for (UIScene *s in scenes) {
        [sceneDesc addObject:[NSString stringWithFormat:@"%@(state=%ld)",
                              NSStringFromClass(object_getClass(s)), (long)s.activationState]];
    }
    WXPProbeLog(@"[侦查] connectedScenes(%lu) = %@",
                (unsigned long)scenes.count,
                sceneDesc.count ? [sceneDesc componentsJoinedByString:@" | "] : @"(空)");

    // 场景管理器
    Class coord = objc_getClass("SBSceneManagerCoordinator");
    WXPProbeLog(@"[侦查] SBSceneManagerCoordinator = %@", coord ? @"存在" : @"不存在(!)");
    if (coord) {
        id shared = WXPSendClassObject(coord, @"sharedInstance");
        NSArray<NSString *> *mgrKeys = @[@"mainDisplaySceneManager",
                                         @"_mainDisplaySceneManager",
                                         @"mainSceneManager"];
        WXPProbeLog(@"[侦查] sharedInstance = %@；取管理器方法：%@",
                    shared ? @"有" : @"nil(!)",
                    WXPListRespondingSelectors(shared, mgrKeys));
        id mgr = nil;
        for (NSString *k in mgrKeys) { mgr = WXPSendObject(shared, k); if (mgr) break; }
        if (mgr) {
            NSArray<NSString *> *hKeys = @[@"_frontmostApplicationSceneHandle",
                                           @"frontmostApplicationSceneHandle",
                                           @"currentLayoutState",
                                           @"layoutState",
                                           @"_layoutState"];
            WXPProbeLog(@"[侦查] 场景管理器(%@) 响应：%@",
                        NSStringFromClass(object_getClass(mgr)),
                        WXPListRespondingSelectors(mgr, hKeys));
        } else {
            WXPProbeLog(@"[侦查] 场景管理器取不到（候选 7~ 不可用）");
        }
    }

    // App 控制器：一次性列全，不要截断（截断会把「有没有 isFrontmost」这条关键信息藏掉）
    Class ac = objc_getClass("SBApplicationController");
    WXPProbeLog(@"[侦查] SBApplicationController = %@", ac ? @"存在" : @"不存在(!)");
    if (ac) {
        id shared = WXPSendClassObject(ac, @"sharedInstance");
        id running = WXPSendObject(shared, @"runningApplications");
        NSUInteger n = 0;
        if ([running isKindOfClass:[NSSet class]]) n = [(NSSet *)running count];
        else if ([running isKindOfClass:[NSArray class]]) n = [(NSArray *)running count];
        WXPProbeLog(@"[侦查] runningApplications = %lu 个", (unsigned long)n);
        for (id app in (id)running) {
            NSString *b = WXPBundleIDFromAny(app, 1);
            WXPProbeLog(@"[侦查]   · %@  isFrontmost=%d _isFrontmost=%d",
                        b ?: @"(取不到 bundle id)",
                        (int)WXPSendBool(app, @"isFrontmost"),
                        (int)WXPSendBool(app, @"_isFrontmost"));
        }
    }

    // 结论
    NSString *path = nil;
    NSString *hit = WXPFrontmostOnce(&path);
    if (hit.length) {
        gWXPHitPath = path;
        WXPProbeLog(@"[侦查] ✅ 当前判定结果：%@（来自 %@）", hit, path);
    } else {
        WXPProbeLog(@"[侦查] ❌ 当前判定结果：判定失败（所有候选都没命中）");
    }
}
