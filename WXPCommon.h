#ifndef WXPCommon_h
#define WXPCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

// ⭐ objc 运行时函数（object_getClass / class_getInstanceMethod / method_copyReturnType /
//    objc_getClass / objc_msgSend ...）必须在这里统一声明。
//    踩坑记录（DecoyLock v0.1.17/v0.1.18）：objc/runtime.h 只在某一个文件里导入过，
//    另一个 .m 是独立编译单元 → 用了却没有可见声明 → CI 报 4 连错
//    （implicit declaration / conflicting types / deprecated-non-prototype）。
//    放进共享头 = 一劳永逸。
#import <objc/runtime.h>
#import <objc/message.h>

#define WXP_VERSION      @"0.1.0"
#define WXP_PREFS_DOMAIN @"com.banliren.wxpet"
#define WXP_NOTIFY_NAME  "com.banliren.wxpet.prefschanged"

// 悬浮窗层级：远高于 App 窗口（UIWindowLevelNormal = 0），
// 又低于系统临时面板（如 SGPanelWindow 的 10001011），保证不跟系统弹层抢。
#define WXP_WINDOW_LEVEL 1000000.0

// 触摸判定的外扩余量（pt）：宠物本体之外再放宽一圈，手感更好，
// 但**绝不能**放宽到整个屏幕 —— 否则会挡住下层 App 的触摸。
#define WXP_HIT_SLOP 10.0

// 默认勾选的 App：只勾微信
#define WXP_DEFAULT_APP_IDS @[@"com.tencent.xin"]

// ---------------------------------------------------------------------------
// 显示范围模式
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, WXPShareMode) {
    WXPShareModeWhitelist = 0,   // 只在勾选的 App 里显示（默认）
    WXPShareModeAll       = 1,   // 所有 App 都显示
    WXPShareModeBlacklist = 2,   // 除勾选的 App 之外都显示
};

// ---------------------------------------------------------------------------
// 共享目录 / 配置读写
//   SpringBoard 进程与「设置」进程都写这里，读取时以文件为准（文件 > NSUserDefaults）。
//   之所以双写：iOS 对 NSUserDefaults 有缓存，而文件是即时的 —— 两边都写最稳。
// ---------------------------------------------------------------------------
FOUNDATION_EXPORT NSString *WXPSharedDir(void);
FOUNDATION_EXPORT NSString *WXPConfigPath(void);
FOUNDATION_EXPORT NSString *WXPProbePath(void);

FOUNDATION_EXPORT NSDictionary *WXPConfigAll(void);
FOUNDATION_EXPORT id   WXPConfigGet(NSString *key);
FOUNDATION_EXPORT void WXPConfigSet(NSString *key, id value);

// 便捷读取（全部带默认值）
FOUNDATION_EXPORT BOOL      WXPEnabled(void);
FOUNDATION_EXPORT NSInteger WXPShareModeValue(void);
FOUNDATION_EXPORT NSArray  *WXPAppIDs(void);
FOUNDATION_EXPORT double    WXPPetScale(void);
FOUNDATION_EXPORT double    WXPPetAlpha(void);
FOUNDATION_EXPORT BOOL      WXPDraggable(void);
FOUNDATION_EXPORT BOOL      WXPSnapEdge(void);
FOUNDATION_EXPORT BOOL      WXPAlwaysShow(void);
FOUNDATION_EXPORT double    WXPPetPosX(void);
FOUNDATION_EXPORT double    WXPPetPosY(void);
FOUNDATION_EXPORT void      WXPSetPetPosition(double x, double y);
FOUNDATION_EXPORT void      WXPResetPetPosition(void);

// ---------------------------------------------------------------------------
// 探针（诊断日志，Filza 友好；多路径兜底）
// ---------------------------------------------------------------------------
FOUNDATION_EXPORT void WXPProbeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *WXPProbeReadAll(void);
FOUNDATION_EXPORT void WXPProbeClear(void);
FOUNDATION_EXPORT NSArray<NSString *> *WXPProbeCandidatePaths(void);

// ---------------------------------------------------------------------------
// 跨进程配置变更通知
//   ⚠️ 用 CFNotificationCenter 的 Darwin 中心，不用 libnotify：
//      它是纯 CoreFoundation，SpringBoard 里必然可用，不需要额外 dylib 依赖。
// ---------------------------------------------------------------------------
FOUNDATION_EXPORT void WXPPostPrefsChanged(void);
FOUNDATION_EXPORT void WXPWatchPrefsChanged(void (^handler)(void));

#endif /* WXPCommon_h */
