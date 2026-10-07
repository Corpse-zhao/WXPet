#ifndef WXPetView_h
#define WXPetView_h

#import <UIKit/UIKit.h>

@class WXPetView;

@protocol WXPetViewDelegate <NSObject>
@optional
// 拖动结束（含吸附动画结束）时回调 —— 用于把位置存下来
- (void)petViewDidFinishDrag:(WXPetView *)pet;
@end

// 宠物本体（可交互层）
//
// ⚠️ 触摸约定：这个视图**只在自己那一小块区域内**参与触摸判定，
//    区域之外由 WXPetWindow 的 hitTest 返回 nil 放行给下层 App。
//    绝不允许把整个屏幕都算成自己的响应区 —— 那会挡住 App 的触摸。
@interface WXPetView : UIView

@property (nonatomic, weak)   id<WXPetViewDelegate> delegate;
@property (nonatomic, assign) BOOL draggable;
@property (nonatomic, assign) BOOL snapEdge;

// 点一下：跳一下 + 撒星星 + 眨个眼
- (void)celebration;

// 吸附到最近的左/右边缘
- (void)snapToEdgeAnimated:(BOOL)animated;

@end

#endif /* WXPetView_h */
