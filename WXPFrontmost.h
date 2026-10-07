#ifndef WXPFrontmost_h
#define WXPFrontmost_h

#import <Foundation/Foundation.h>

// 当前前台 App 的 bundle id。取不到返回 nil。
// ⚠️ 必须 fail-closed：判定不出来时返回 nil，由调用方决定「不显示」，
//    绝不允许默认返回某个值 —— 那会让「仅在指定 App 显示」静默失效。
FOUNDATION_EXPORT NSString *WXPFrontmostBundleID(void);

// 启动时把整条候选链的侦查结果打进探针。
// 目的：把「判定失败」从「猜」变成「看日志」——一次真机反馈就能定位。
FOUNDATION_EXPORT void WXPFrontmostRecon(void);

#endif /* WXPFrontmost_h */
