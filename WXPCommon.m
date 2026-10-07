#import "WXPCommon.h"

// ---------------------------------------------------------------------------
// 共享目录
//
//  为什么不用沙盒路径：SpringBoard 在越狱环境下不受沙盒约束，而「设置」App 是
//  系统 App，两边的沙盒 Documents 是**不同**的目录。要用同一个文件通信，
//  只能选一个双方都能写的位置 —— /var/mobile/Documents 是最常用的那个。
//  读不到时退回沙盒（至少插件自己还能写日志）。
// ---------------------------------------------------------------------------
static NSString *WXPDocumentsBase(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/var/mobile/Documents"]) {
        return @"/var/mobile/Documents";
    }
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                      NSUserDomainMask, YES).firstObject;
    if (d.length) return d;
    return NSTemporaryDirectory();
}

static NSString *WXPEnsureDir(NSString *d) {
    if (!d.length) return d;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) return d;
    [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    // Filza 友好：允许 mobile 读写（否则用户在文件管理器里改不动配置）
    [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:d error:NULL];
    return d;
}

NSString *WXPSharedDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [WXPDocumentsBase() stringByAppendingPathComponent:@"悬浮宠物"];
    });
    return dir;
}

NSString *WXPConfigPath(void) {
    return [WXPSharedDir() stringByAppendingPathComponent:@"_config.plist"];
}

// ---------------------------------------------------------------------------
// 探针路径：⭐ 多路径兜底
//
//  血泪（WXGlass v0.1.2 定位失败一轮）：探针只写一条路径，而「设置」App 是
//  沙盒进程，写不进 /var/mobile/Documents —— 于是「写失败」和「没注入」
//  在用户侧长得一模一样，排查方向被带偏一整轮。
//  这里按顺序试，第一个写得进去的胜出，并把它缓存下来。
// ---------------------------------------------------------------------------
NSArray<NSString *> *WXPProbeCandidatePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:[WXPSharedDir() stringByAppendingPathComponent:@"_probe.txt"]];
    [a addObject:@"/var/mobile/Library/WXPet/_probe.txt"];
    [a addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/_wxpet_probe.txt"]];
    [a addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"_wxpet_probe.txt"]];
    return a;
}

NSString *WXPProbePath(void) {
    static NSString *resolved = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *cands = WXPProbeCandidatePaths();
        for (NSString *p in cands) {
            WXPEnsureDir([p stringByDeletingLastPathComponent]);
            if ([fm fileExistsAtPath:p]) { resolved = p; return; }
            if ([[NSData data] writeToFile:p atomically:YES]) { resolved = p; return; }
        }
        resolved = cands.firstObject;
    });
    return resolved;
}

void WXPProbeLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *path = WXPProbePath();
    if (!path.length) return;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@ (pid %d)\n",
                      [df stringFromDate:[NSDate date]], body, (int)getpid()];

    NSFileManager *fm = [NSFileManager defaultManager];

    // 限长：超过 256KB 只保留最后 128KB，避免长期运行把日志写爆
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
    if (size > (unsigned long long)(256 * 1024)) {
        NSString *all = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (all.length > 128 * 1024) {
            all = [all substringFromIndex:all.length - 128 * 1024];
        }
        [(all ?: @"") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    }
}

NSString *WXPProbeReadAll(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *p in WXPProbeCandidatePaths()) {
        NSString *s = [NSString stringWithContentsOfFile:p
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        if (s.length) [parts addObject:s];
    }
    return parts.count ? [parts componentsJoinedByString:@"\n"] : @"";
}

void WXPProbeClear(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WXPProbeCandidatePaths()) {
        [fm removeItemAtPath:p error:NULL];
    }
}

// ---------------------------------------------------------------------------
// 配置读写
// ---------------------------------------------------------------------------
NSDictionary *WXPConfigAll(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // 1) NSUserDefaults(suite) 打底 —— 「设置」进程写这里最方便
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:WXP_PREFS_DOMAIN];
    NSDictionary *snap = [d dictionaryRepresentation];
    if (snap.count) [out addEntriesFromDictionary:snap];

    // 2) 共享文件覆盖 —— 即时、无缓存，插件侧以它为准
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:WXPConfigPath()];
    if (file.count) [out addEntriesFromDictionary:file];

    return out;
}

id WXPConfigGet(NSString *key) {
    if (!key.length) return nil;
    return WXPConfigAll()[key];
}

void WXPConfigSet(NSString *key, id value) {
    if (!key.length) return;
    WXPEnsureDir(WXPSharedDir());

    NSMutableDictionary *cfg =
        [NSMutableDictionary dictionaryWithContentsOfFile:WXPConfigPath()];
    if (!cfg) cfg = [NSMutableDictionary dictionary];
    if (value) cfg[key] = value; else [cfg removeObjectForKey:key];
    [cfg writeToFile:WXPConfigPath() atomically:YES];

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:WXP_PREFS_DOMAIN];
    if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
    [d synchronize];
}

// ------------------------------ 便捷读取 ------------------------------

static BOOL WXPBoolValue(NSString *key, BOOL def) {
    id v = WXPConfigGet(key);
    if (!v) return def;
    return [v boolValue];
}

static double WXPDoubleValue(NSString *key, double def, double lo, double hi) {
    id v = WXPConfigGet(key);
    if (!v) return def;
    double d = [v doubleValue];
    if (d < lo) d = lo;
    if (d > hi) d = hi;
    return d;
}

BOOL WXPEnabled(void) {
    return WXPBoolValue(@"enabled", NO);
}

NSInteger WXPShareModeValue(void) {
    id v = WXPConfigGet(@"share_mode");
    if (!v) return WXPShareModeWhitelist;
    NSInteger m = [v integerValue];
    if (m < 0 || m > 2) m = WXPShareModeWhitelist;
    return m;
}

NSArray *WXPAppIDs(void) {
    id v = WXPConfigGet(@"app_ids");
    if ([v isKindOfClass:[NSArray class]]) return v;
    // 未设置过 → 默认只勾微信
    return WXP_DEFAULT_APP_IDS;
}

double WXPPetScale(void) {
    return WXPDoubleValue(@"pet_scale", 1.0, 0.5, 2.0);
}

double WXPPetAlpha(void) {
    return WXPDoubleValue(@"pet_alpha", 1.0, 0.15, 1.0);
}

BOOL WXPDraggable(void) {
    return WXPBoolValue(@"draggable", YES);
}

BOOL WXPSnapEdge(void) {
    return WXPBoolValue(@"snap_edge", YES);
}

BOOL WXPAlwaysShow(void) {
    return WXPBoolValue(@"always_show", NO);
}

double WXPPetPosX(void) {
    return WXPDoubleValue(@"pet_pos_x", 0.86, 0.0, 1.0);
}

double WXPPetPosY(void) {
    return WXPDoubleValue(@"pet_pos_y", 0.62, 0.0, 1.0);
}

void WXPSetPetPosition(double x, double y) {
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    if (y < 0.0) y = 0.0;
    if (y > 1.0) y = 1.0;
    WXPConfigSet(@"pet_pos_x", @(x));
    WXPConfigSet(@"pet_pos_y", @(y));
}

void WXPResetPetPosition(void) {
    WXPConfigSet(@"pet_pos_x", @(0.86));
    WXPConfigSet(@"pet_pos_y", @(0.62));
}

// ---------------------------------------------------------------------------
// 跨进程通知（Darwin 通知）
// ---------------------------------------------------------------------------
void WXPPostPrefsChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(WXP_NOTIFY_NAME), NULL, NULL, true);
}

static void (^gWXPWatchHandler)(void) = nil;

static void WXPNotifyCallback(CFNotificationCenterRef center,
                              void *observer,
                              CFNotificationName name,
                              const void *object,
                              CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    void (^h)(void) = gWXPWatchHandler;
    if (!h) return;
    if ([NSThread isMainThread]) h();
    else dispatch_async(dispatch_get_main_queue(), h);
}

void WXPWatchPrefsChanged(void (^handler)(void)) {
    if (!handler) return;
    gWXPWatchHandler = [handler copy];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        WXPNotifyCallback,
                                        CFSTR(WXP_NOTIFY_NAME),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}
