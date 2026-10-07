#ifndef WXPetManager_h
#define WXPetManager_h

#import <Foundation/Foundation.h>

// 悬浮宠物的总调度：建窗口、判前台、控显示、存位置。
//
// start 是幂等的 —— %ctor 和 SpringBoard 的启动回调都会调它，
// 谁先到都行，重复调用只会重新加载配置，不会重复建窗口。
@interface WXPetManager : NSObject

+ (instancetype)shared;
- (void)start;
- (void)reloadPrefs;

@end

#endif /* WXPetManager_h */
