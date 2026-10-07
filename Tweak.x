#import "WXPCommon.h"
#import "WXPFrontmost.h"
#import "WXPetManager.h"

// ═══════════════════════════════════════════════════════════════════════════
//  WXPet 悬浮宠物
//
//  ⭐⭐ 本插件**只注入 com.apple.springboard 一个进程**。
//
//  悬浮宠物 = SpringBoard 里的一个高层级窗口（windowLevel = 1000000）。
//  渲染服务器按 windowLevel 合成，所以它天然盖在所有 App 的窗口之上 ——
//  微信只是「被盖住」的那个，我们不需要往它里面塞任何东西。
//  「只在某些 App 显示」也由 SpringBoard 自己判断（它本来就知道当前前台是谁）。
//
//  这样做的收益：不逆向、不修改任何第三方 App 的二进制，
//  不违反其用户协议，没有账号封禁风险。装饰层就该待在装饰层。
//
//  ⚠️ 不要手写 %init！
//     Logos 源码（bin/logos.pl）实锤：
//       · %ctor 展开为**独立**的 constructor；
//       · 默认构造器 _logosLocalInit() 只在「全文件没有任何 %init」时才生成；
//       · %init 是「把 group 初始化语句就地展开」，手写会造成前置引用 →
//         use of undeclared identifier / MSHookMessageEx 未声明 → 编译直接失败。
//     结论：%ctor 照写，%init 一个都不要写。
// ═══════════════════════════════════════════════════════════════════════════

%ctor {
    // ⭐ 启动横幅必须放在**一切判定之前**（WXGlass v0.2.0 血泪）。
    //   如果先做判定、不中就 return，探针里连一行都没有 ——
    //   「没注入」和「注入了但被判定滤掉」就长得一模一样，没法定位。
    WXPProbeLog(@"════ WXPet %@ 启动 ════", WXP_VERSION);
    WXPProbeLog(@"[进程] pid=%d name=%@ bundle=%@",
                (int)getpid(),
                [[NSProcessInfo processInfo] processName] ?: @"(nil)",
                [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)");

    // 启动时把整条「前台判定候选链」的侦查结果落盘 ——
    // 一次真机反馈就能定位是哪条候选命中/全都没命中，不用再猜。
    WXPFrontmostRecon();

    // SpringBoard 启动早期可能还取不到窗口场景，延后 2 秒再建窗口。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[WXPetManager shared] start];
    });
}

// 兜底启动点。start 是幂等的，重复调用只会重新加载一次配置。
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    WXPProbeLog(@"[生命周期] SpringBoard applicationDidFinishLaunching");
    [[WXPetManager shared] start];
}

%end
