#ifndef WXPetWindow_h
#define WXPetWindow_h

#import <UIKit/UIKit.h>
#import "WXPetView.h"

// 承载悬浮宠物的窗口（活在 SpringBoard 进程里）
//
// 三条铁律（都来自真实事故）：
//   ① **绝不 makeKeyAndVisible** —— 抢走系统 key window 会让下层界面点不动；
//      显示只需要 hidden = NO + 层级够高。
//   ② **hitTest 必须在宠物区域之外返回 nil** —— 这个窗口铺满全屏，
//      不放行的话会把下层 App 的所有点击吃掉。
//   ③ **必须挂到 windowScene** —— iOS 13+ 没挂 scene 的窗口根本不会显示，
//      而且不会有任何报错（典型「代码全对但屏幕上什么都没有」）。
@interface WXPetWindow : UIWindow

@property (nonatomic, strong) WXPetView *petView;

// 挂到 SpringBoard 的窗口场景上；返回 NO 表示当前还取不到 scene（调用方可重试）
- (BOOL)attachToScene;

@end

#endif /* WXPetWindow_h */
