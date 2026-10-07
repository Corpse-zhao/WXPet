#import "WXPetPrefsListController.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

// libproc.h 不在 iOS SDK 里，但这些函数在 libSystem 中 —— 手动声明
#define PROC_ALL_PIDS 1
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(pid_t pid, void *buffer, uint32_t buffersize);

// ═══════════════════════════════════════════════════════════════════════════
//  设置面板
//
//  ⚠️ 架构约束：prefs bundle **不加载插件 dylib**，拿不到 WXPCommon 的符号。
//     所以这里必须自带一份配置读写 / 探针 / 版本常量 —— 与插件端格式保持一致，
//     这样两边的日志落在同一个 _probe.txt 里，排查时时间线能对上。
// ═══════════════════════════════════════════════════════════════════════════

static NSString *const kWXPDomain        = @"com.banliren.wxpet";
static NSString *const kWXPNotifyName    = @"com.banliren.wxpet.prefschanged";
// ⚠️ 必须手写：面板版本要跟 control / WXPCommon.h 的 WXP_VERSION 完全一致，
//    诊断页拿它跟「插件启动横幅」里的版本比对，一眼看出 SpringBoard 里跑的是不是新版。
static NSString *const kWXPPrefsVersion  = @"0.1.0";

// ---------------------------------------------------------------------------
// 路径（与插件端同一套候选逻辑）
// ---------------------------------------------------------------------------
static NSString *WXPPrefsBase(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents"]) {
        return @"/var/mobile/Documents";
    }
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                      NSUserDomainMask, YES).firstObject;
    return d.length ? d : NSTemporaryDirectory();
}

static void WXPPrefsEnsureDir(NSString *d) {
    if (!d.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) return;
    [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:d error:NULL];
}

static NSString *WXPPrefsSharedDir(void) {
    return [WXPPrefsBase() stringByAppendingPathComponent:@"悬浮宠物"];
}

static NSString *WXPPrefsConfigPath(void) {
    return [WXPPrefsSharedDir() stringByAppendingPathComponent:@"_config.plist"];
}

static NSArray<NSString *> *WXPPrefsProbeCandidates(void) {
    return @[[WXPPrefsSharedDir() stringByAppendingPathComponent:@"_probe.txt"],
             @"/var/mobile/Library/WXPet/_probe.txt",
             [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/_wxpet_probe.txt"],
             [NSTemporaryDirectory() stringByAppendingPathComponent:@"_wxpet_probe.txt"]];
}

// 探针：多路径兜底 ——「设置」App 是沙盒进程，写不进 /var/mobile/Documents 时
// 必须换一条能写的位置，否则「写失败」会被误判成「插件没生效」。
static NSString *WXPPrefsProbePath(void) {
    static NSString *resolved = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *cands = WXPPrefsProbeCandidates();
        for (NSString *p in cands) {
            WXPPrefsEnsureDir([p stringByDeletingLastPathComponent]);
            if ([fm fileExistsAtPath:p]) { resolved = p; return; }
            if ([[NSData data] writeToFile:p atomically:YES]) { resolved = p; return; }
        }
        resolved = cands.firstObject;
    });
    return resolved;
}

static void WXPPrefsLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void WXPPrefsLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] [设置] %@ (pid %d)\n",
                      [df stringFromDate:[NSDate date]], body, (int)getpid()];

    NSString *path = WXPPrefsProbePath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) { [data writeToFile:path atomically:YES]; return; }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    }
}

static NSString *WXPPrefsProbeReadAll(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *p in WXPPrefsProbeCandidates()) {
        NSString *s = [NSString stringWithContentsOfFile:p
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        if (s.length) [parts addObject:s];
    }
    return parts.count ? [parts componentsJoinedByString:@"\n"] : @"";
}

static void WXPPrefsProbeClear(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WXPPrefsProbeCandidates()) [fm removeItemAtPath:p error:NULL];
}

// ---------------------------------------------------------------------------
// 配置读写：共享文件（权威、无缓存）+ NSUserDefaults（跨进程即时），然后发通知
// ---------------------------------------------------------------------------
static NSMutableDictionary *WXPPrefsLoad(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kWXPDomain];
    NSDictionary *snap = [d dictionaryRepresentation];
    if (snap.count) [out addEntriesFromDictionary:snap];
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:WXPPrefsConfigPath()];
    if (file.count) [out addEntriesFromDictionary:file];
    return out;
}

static void WXPPrefsSave(NSDictionary *cfg) {
    WXPPrefsEnsureDir(WXPPrefsSharedDir());
    [cfg writeToFile:WXPPrefsConfigPath() atomically:YES];

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kWXPDomain];
    for (NSString *k in cfg) [d setObject:cfg[k] forKey:k];
    [d synchronize];

    // Darwin 通知：插件侧用 CFNotificationCenter 监听同一个名字
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kWXPNotifyName,
                                         NULL, NULL, true);
}

// ---------------------------------------------------------------------------
// 受保护的消息发送（只转发「确实返回对象」的方法，避免把 BOOL 方法当对象方法调）
// ---------------------------------------------------------------------------
static BOOL WXPSelectorReturnsObject(id obj, SEL sel) {
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) m = class_getInstanceMethod([obj class], sel);
    if (!m) return NO;
    char *rt = method_copyReturnType(m);
    if (!rt) return NO;
    BOOL ok = (rt[0] == '@' && rt[1] != '?');
    free(rt);
    return ok;
}

static id WXPSendObject(id target, NSString *name) {
    if (!target || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![target respondsToSelector:sel]) return nil;
    if (!WXPSelectorReturnsObject(target, sel)) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

static NSString *WXPStringOf(id v) {
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

// ---------------------------------------------------------------------------
// 枚举已安装 App
//   LSApplicationWorkspace 拿不到时退回「扫 /var/containers/Bundle/Application」，
//   保证选择器永远不会是空列表（空列表 = 用户以为插件坏了）。
// ---------------------------------------------------------------------------
static void WXPAddApp(NSMutableArray<NSDictionary *> *out, NSMutableSet *seen,
                      NSString *bundleID, NSString *name) {
    if (!bundleID.length || !name.length) return;
    if ([seen containsObject:bundleID]) return;
    [seen addObject:bundleID];
    [out addObject:@{@"id": bundleID, @"name": name}];
}

static void WXPCollectFromFilesystem(NSMutableArray<NSDictionary *> *out, NSMutableSet *seen) {
    NSString *base = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *level1 = [fm contentsOfDirectoryAtPath:base error:NULL];
    for (NSString *d1 in level1) {
        NSString *sub = [base stringByAppendingPathComponent:d1];
        NSArray<NSString *> *level2 = [fm contentsOfDirectoryAtPath:sub error:NULL];
        for (NSString *n in level2) {
            if (![n hasSuffix:@".app"]) continue;
            NSString *infoPath = [[sub stringByAppendingPathComponent:n]
                                  stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (![pl isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = WXPStringOf(pl[@"CFBundleIdentifier"]);
            if (!bid.length) continue;
            NSString *name = WXPStringOf(pl[@"CFBundleDisplayName"])
                          ?: WXPStringOf(pl[@"CFBundleName"])
                          ?: [n stringByDeletingPathExtension];
            WXPAddApp(out, seen, bid, name);
        }
    }
}

static NSArray<NSDictionary *> *WXPInstalledApps(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    // ① LSApplicationWorkspace（私有框架，按需 dlopen）
    if (!NSClassFromString(@"LSApplicationWorkspace")) {
        dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    }
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls) {
        id ws = WXPSendObject((id)wsCls, @"defaultWorkspace");
        NSArray *all = (NSArray *)WXPSendObject(ws, @"allInstalledApplications");
        if (!all.count) all = (NSArray *)WXPSendObject(ws, @"allApplications");
        for (id proxy in all) {
            NSString *bid = WXPStringOf(WXPSendObject(proxy, @"bundleIdentifier"));
            if (!bid.length) continue;
            NSString *type = WXPStringOf(WXPSendObject(proxy, @"applicationType"));
            if (type.length && [type isEqualToString:@"Internal"]) continue;
            NSString *name = WXPStringOf(WXPSendObject(proxy, @"localizedName"))
                          ?: WXPStringOf(WXPSendObject(proxy, @"itemName"));
            if (!name.length) name = bid;
            WXPAddApp(out, seen, bid, name);
        }
        WXPPrefsLog(@"LSApplicationWorkspace 枚举到 %lu 个 App", (unsigned long)out.count);
    } else {
        WXPPrefsLog(@"⚠️ LSApplicationWorkspace 不可用，改用文件系统枚举");
    }

    // ② 文件系统兜底
    if (out.count < 5) {
        WXPCollectFromFilesystem(out, seen);
        WXPPrefsLog(@"文件系统兜底枚举后共 %lu 个 App", (unsigned long)out.count);
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return out;
}

// App 图标：两条私有 API 候选，全都拿不到就返回 nil（单元格退化为纯文字，不影响功能）
static UIImage *WXPAppIcon(NSString *bundleID) {
    if (!bundleID.length) return nil;
    Class iconCls = [UIImage class];
    @try {
        SEL s3 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([iconCls respondsToSelector:s3]) {
            typedef id (*Fn3)(id, SEL, NSString *, int, CGFloat);
            id v = ((Fn3)objc_msgSend)(iconCls, s3, bundleID, 0, 3.0);
            if ([v isKindOfClass:[UIImage class]]) return v;
        }
        SEL s2 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
        if ([iconCls respondsToSelector:s2]) {
            typedef id (*Fn2)(id, SEL, NSString *, int);
            id v = ((Fn2)objc_msgSend)(iconCls, s2, bundleID, 0);
            if ([v isKindOfClass:[UIImage class]]) return v;
        }
    } @catch (__unused NSException *e) {
        return nil;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// 重启桌面
//   ⚠️ 不用 system()（iOS SDK 标了 unavailable，编译必挂）；
//      优先 proc_listpids + kill(SIGKILL) —— 无子进程、无 PATH 依赖；
//      killall 作为备用，且路径要考虑 roothide 的随机 jbroot。
// ---------------------------------------------------------------------------
static NSString *WXPKillallPath(void) {
    if (access("/usr/bin/killall", X_OK) == 0) return @"/usr/bin/killall";

    Dl_info info;
    if (dladdr((void *)&WXPKillallPath, &info) && info.dli_fname) {
        NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
        NSRange r = [selfPath rangeOfString:@"/Library/PreferenceBundles/"];
        if (r.location != NSNotFound) {
            NSString *jbroot = [selfPath substringToIndex:r.location];
            NSString *cand = [jbroot stringByAppendingPathComponent:@"usr/bin/killall"];
            if (access([cand fileSystemRepresentation], X_OK) == 0) return cand;
        }
    }
    return nil;
}

static void WXPDoRespring(void) {
    BOOL killed = NO;
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n > 0) {
        pid_t *pids = (pid_t *)calloc(1, (size_t)n + 64);
        if (pids) {
            int m = proc_listpids(PROC_ALL_PIDS, 0, pids, n + 64);
            int count = m / (int)sizeof(pid_t);
            for (int i = 0; i < count; i++) {
                char pname[256] = {0};
                if (proc_name(pids[i], pname, sizeof(pname)) <= 0) continue;
                if (strcmp(pname, "SpringBoard") == 0) {
                    if (kill(pids[i], SIGKILL) == 0) killed = YES;
                    break;
                }
            }
            free(pids);
        }
    }

    if (killed) return;

    NSString *kp = WXPKillallPath();
    if (!kp) return;
    pid_t pid = 0;
    int st = 0;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    if (posix_spawn(&pid, [kp fileSystemRepresentation], NULL, NULL, (char *const *)args, NULL) == 0) {
        waitpid(pid, &st, 0);
    }
}

#pragma mark - 主面板

@implementation WXPetPrefsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮宠物";
    WXPPrefsLog(@"面板打开（面板版本 %@）", kWXPPrefsVersion);
}

// ⭐ 覆盖这两个方法：让 plist 驱动的开关/滑杆直接落到**我们自己的**配置里。
//    不覆盖的话，PSListController 会写它自己认定的域（通常是 prefs bundle 的
//    bundle id），插件侧读不到 —— 开关点了没反应，且完全不报错。
- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSDictionary *cfg = WXPPrefsLoad();
    id v = cfg[key];
    if (v) return v;
    return [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;

    NSMutableDictionary *cfg = WXPPrefsLoad();
    cfg[key] = value;
    WXPPrefsSave(cfg);
    WXPPrefsLog(@"%@ = %@", key, value);
}

#pragma mark - 跳转

- (void)pushAppPicker:(PSSpecifier *)spec {
    (void)spec;
    WXPPrefsLog(@"点中「选择显示的 App」");
    WXPAppPickerController *vc = [[WXPAppPickerController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = self.navigationController;
    if (nav) [nav pushViewController:vc animated:YES];
    else [self presentViewController:vc animated:YES completion:nil];
}

- (void)pushShareMode:(PSSpecifier *)spec {
    (void)spec;
    WXPPrefsLog(@"点中「显示范围模式」");
    WXPShareModeController *vc = [[WXPShareModeController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = self.navigationController;
    if (nav) [nav pushViewController:vc animated:YES];
    else [self presentViewController:vc animated:YES completion:nil];
}

#pragma mark - 按钮

- (void)resetPosition {
    NSMutableDictionary *cfg = WXPPrefsLoad();
    cfg[@"pet_pos_x"] = @(0.86);
    cfg[@"pet_pos_y"] = @(0.62);
    WXPPrefsSave(cfg);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已重置位置"
                                                               message:@"宠物回到屏幕右下角。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showProbe {
    WXPProbeController *vc = [[WXPProbeController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = self.navigationController;
    if (nav) [nav pushViewController:vc animated:YES];
    else [self presentViewController:vc animated:YES completion:nil];
}

- (void)clearProbe {
    WXPPrefsProbeClear();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已清除"
                                                               message:@"诊断日志已清空。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)respring {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"重启桌面"
                         message:@"将结束 SpringBoard 使其重新加载插件。屏幕会短暂黑屏，属正常现象。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        (void)a;
        WXPDoRespring();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - App 选择器

@implementation WXPAppPickerController {
    NSMutableArray<NSDictionary *> *_allApps;
    NSMutableArray<NSDictionary *> *_shownApps;
    NSMutableSet *_selected;
    NSMutableDictionary *_iconCache;
    UISearchBar *_searchBar;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择显示的 App";
    self.tableView.rowHeight = 52.0;

    _allApps = [NSMutableArray array];
    _shownApps = [NSMutableArray array];
    _iconCache = [NSMutableDictionary dictionary];

    NSDictionary *cfg = WXPPrefsLoad();
    NSArray *cur = cfg[@"app_ids"];
    if ([cur isKindOfClass:[NSArray class]]) {
        _selected = [NSMutableSet setWithArray:cur];
    } else {
        _selected = [NSMutableSet setWithArray:@[@"com.tencent.xin"]];   // 默认勾微信
    }

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
    _searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    _searchBar.delegate = self;
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tableView.tableHeaderView = _searchBar;

    // 枚举放后台，避免进面板时卡一下
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *apps = WXPInstalledApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            WXPAppPickerController *me = weakSelf;
            if (!me) return;
            [me->_allApps setArray:apps];
            [me applyFilter];
            [me.tableView reloadData];
        });
    });
}

- (void)applyFilter {
    NSString *kw = [_searchBar.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [_shownApps removeAllObjects];
    for (NSDictionary *a in _allApps) {
        if (!kw.length
            || [a[@"name"] rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound
            || [a[@"id"]   rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [_shownApps addObject:a];
        }
    }
}

- (void)save {
    NSMutableDictionary *cfg = WXPPrefsLoad();
    // 保持列表顺序，输出稳定（便于人工核对）
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSDictionary *a in _allApps) {
        if ([_selected containsObject:a[@"id"]]) [ordered addObject:a[@"id"]];
    }
    cfg[@"app_ids"] = ordered;
    WXPPrefsSave(cfg);
    WXPPrefsLog(@"已保存显示名单：%lu 个", (unsigned long)ordered.count);
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    return (NSInteger)_shownApps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv; (void)s;
    return [NSString stringWithFormat:@"已勾选 %lu 个 · 点右上角「完成」保存",
            (unsigned long)_selected.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    (void)tv; (void)s;
    return @"勾选后，宠物只会在这些 App 里出现（默认只勾「微信」）。"
            "想改成「所有 App 都显示」，回上一页改「显示范围模式」。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"WXPAppPickerCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
        cell.textLabel.font = [UIFont systemFontOfSize:16.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    if (ip.row < 0 || ip.row >= (NSInteger)_shownApps.count) return cell;

    NSDictionary *a = _shownApps[(NSUInteger)ip.row];
    cell.textLabel.text = a[@"name"];
    cell.detailTextLabel.text = a[@"id"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = [_selected containsObject:a[@"id"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    UIImage *icon = _iconCache[a[@"id"]];
    if (!icon) {
        icon = WXPAppIcon(a[@"id"]);
        if (icon) _iconCache[a[@"id"]] = icon; else _iconCache[a[@"id"]] = [NSNull null];
    }
    cell.imageView.image = ([icon isKindOfClass:[UIImage class]]) ? icon : nil;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < 0 || ip.row >= (NSInteger)_shownApps.count) return;

    NSString *bid = _shownApps[(NSUInteger)ip.row][@"id"];
    if ([_selected containsObject:bid]) [_selected removeObject:bid];
    else                                [_selected addObject:bid];

    // 整节重载：勾选状态和表头的「已勾选 N 个」计数一起刷新
    [tv reloadSections:[NSIndexSet indexSetWithIndex:0]
      withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark 搜索

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    (void)sb; (void)text;
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

@end

#pragma mark - 显示范围模式

// ⚠️ 必须先声明：cellForRowAtIndexPath: 里要用它，而它的定义在文件更下面 ——
//    不声明的话编译器会按「返回 id」处理，赋给 NSInteger 直接出警告/错误。
@interface WXPShareModeController ()
+ (NSInteger)currentMode;
@end

@implementation WXPShareModeController {
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_details;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"显示范围模式";
    _titles = @[@"只在勾选的 App 显示", @"所有 App 都显示", @"除勾选的 App 之外都显示"];
    _details = @[@"默认。配合「选择显示的 App」使用",
                 @"包括桌面、设置页、所有第三方 App",
                 @"勾选的 App 里不出现，其它地方都出现"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    return (NSInteger)_titles.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    (void)tv; (void)s;
    return @"改完立即生效，不用重启桌面。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"WXPShareModeCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    NSInteger mode = [WXPShareModeController currentMode];
    cell.textLabel.text = _titles[(NSUInteger)ip.row];
    cell.detailTextLabel.text = _details[(NSUInteger)ip.row];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = ((NSInteger)ip.row == mode)
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSMutableDictionary *cfg = WXPPrefsLoad();
    cfg[@"share_mode"] = @(ip.row);
    WXPPrefsSave(cfg);
    WXPPrefsLog(@"显示范围模式 → %ld", (long)ip.row);
    [tv reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

+ (NSInteger)currentMode {
    id v = WXPPrefsLoad()[@"share_mode"];
    if (!v) return 0;
    NSInteger m = [v integerValue];
    return (m < 0 || m > 2) ? 0 : m;
}

@end

#pragma mark - 运行诊断

@implementation WXPProbeController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行诊断";
    self.tableView.rowHeight = 22.0;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(copyAll)];
    [self reload];
}

- (void)reload {
    NSString *raw = WXPPrefsProbeReadAll();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    // ── 版本自检（放最前面，这是「装了新版但没生效」的唯一可靠判据）──
    // 探针是追加式，每次重启桌面就多一条横幅 → 必须从**后**往前取最新一条。
    NSString *running = @"(未检测到)";
    NSArray<NSString *> *all = [raw componentsSeparatedByString:@"\n"];
    for (NSInteger i = (NSInteger)all.count - 1; i >= 0; i--) {
        NSString *ln = all[(NSUInteger)i];
        if ([ln rangeOfString:@"WXPet "].location == NSNotFound) continue;
        if ([ln rangeOfString:@"启动"].location == NSNotFound) continue;
        NSRange r = [ln rangeOfString:@"WXPet "];
        NSString *tail = [ln substringFromIndex:r.location + r.length];
        NSRange sp = [tail rangeOfString:@" "];
        running = (sp.location != NSNotFound) ? [tail substringToIndex:sp.location] : tail;
        break;
    }

    // ── 前台判定链命中的是哪条 ──
    NSString *hitPath = @"(未记录)";
    for (NSInteger i = (NSInteger)all.count - 1; i >= 0; i--) {
        NSString *ln = all[(NSUInteger)i];
        if ([ln rangeOfString:@"[前台] 判定链命中："].location == NSNotFound) continue;
        NSRange r = [ln rangeOfString:@"[前台] 判定链命中："];
        hitPath = [[ln substringFromIndex:r.location + r.length]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        break;
    }

    [lines addObject:[NSString stringWithFormat:@"面板版本：%@", kWXPPrefsVersion]];
    [lines addObject:[NSString stringWithFormat:@"运行版本：%@", running]];
    if ([running isEqualToString:kWXPPrefsVersion]) {
        [lines addObject:@"✅ 版本一致"];
    } else if ([running isEqualToString:@"(未检测到)"]) {
        [lines addObject:@"❌ 探针里没有启动横幅 → 插件 dylib 没被加载（需要重启桌面）"];
    } else {
        [lines addObject:@"⚠️ 版本不一致 → 多半只是改完没重启桌面"];
    }
    [lines addObject:[NSString stringWithFormat:@"前台判定链：%@", hitPath]];
    [lines addObject:@""];
    [lines addObject:@"──────── 日志 ────────"];

    NSArray<NSString *> *tailLines = [raw componentsSeparatedByString:@"\n"];
    NSUInteger start = 0;
    if (tailLines.count > 400) start = tailLines.count - 400;   // 只显示最后 400 行
    for (NSUInteger i = start; i < tailLines.count; i++) {
        [lines addObject:tailLines[i]];
    }
    if (lines.count <= 6) [lines addObject:@"（暂无日志）"];

    self.lines = lines;
    self.plain = [lines componentsJoinedByString:@"\n"];
    [self.tableView reloadData];
}

- (void)copyAll {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = self.plain ?: @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制"
                                                               message:@"诊断内容已复制到剪贴板。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    return (NSInteger)self.lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"WXPProbeCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = (ip.row < (NSInteger)self.lines.count) ? self.lines[(NSUInteger)ip.row] : @"";
    cell.textLabel.textColor = [UIColor labelColor];
    return cell;
}

@end
