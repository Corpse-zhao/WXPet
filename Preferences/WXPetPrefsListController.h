#ifndef WXPetPrefsListController_h
#define WXPetPrefsListController_h

#import <UIKit/UIKit.h>

// ⚠️ PSListController 的私有声明（配合 -Wl,-undefined,dynamic_lookup，不链接 Preferences.framework）
//
// 血泪（DecoyLock v0.1.4）：`_specifiers` ivar **必须声明在基类接口里** ——
// PSListController 的表格数据源直接访问自己的 `_specifiers` ivar（编译期绑定），
// 子类写别处基类永远看到 nil，现象就是「能点进面板但整页空白」。
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    @protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (UITableView *)table;
@end

// 主面板：保留 PSListController（Root.plist 驱动，开关/滑杆最稳）
@interface WXPetPrefsListController : PSListController
@end

// ⚠️ 以下控制器**不继承 PSListController**，纯原生 UIKit。
//    原因（DecoyLock 实测）：手搓 PSSpecifier（[PSSpecifier new] + setValue:forKey:）
//    极脆弱，会出现「点击闪退 / 点了没反应」；改用原生 UITableViewController 后
//    零私有 API 构造依赖。

// App 选择器（枚举已安装 App，带图标与搜索）
// ⚠️ 必须显式声明 <UISearchBarDelegate>：否则 _searchBar.delegate = self 会报
//    「incompatible pointer types assigning to id<UISearchBarDelegate>」
//    —— -Wall 下这是条实打实的警告，Theos 一旦带 -Werror 就直接编译不过。
@interface WXPAppPickerController : UITableViewController <UISearchBarDelegate>
@end

// 显示范围模式选择（3 选 1）
@interface WXPShareModeController : UITableViewController
@end

// 运行诊断查看器（原生表格 + 一键复制）
@interface WXPProbeController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *lines;
@property (nonatomic, copy)   NSString *plain;
@end

#endif /* WXPetPrefsListController_h */
