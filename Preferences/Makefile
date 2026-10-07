include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WXPetPrefs
WXPetPrefs_FILES = WXPetPrefsListController.m
WXPetPrefs_INSTALL_PATH = /Library/PreferenceBundles
WXPetPrefs_FRAMEWORKS = UIKit

# ⚠️ PSListController / PSSpecifier 是私有类：我们在头文件里自己声明接口，
#    链接时用 dynamic_lookup 在运行时解析 —— **不链接 Preferences.framework**。
#    好处是 Makefile 里不用写死某个 SDK 的具体路径
#    （写死 `-F$(THEOS)/sdks/iPhoneOS16.5.sdk/...` 在换 SDK 时会直接找不到库）。
WXPetPrefs_CFLAGS = -fobjc-arc -Wall -Wno-unused-function
WXPetPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

# Resources/ 下的 Info.plist 与 Root.plist 会被平铺进 bundle 根目录：
#   · Info.plist 的 NSPrincipalClass 决定入口控制器（放错位置 = 点进去白屏）
#   · Root.plist 是 PSListController 默认加载的面板定义
WXPetPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
