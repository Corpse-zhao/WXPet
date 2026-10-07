# ═══════════════════════════════════════════════════════════════════════
#  悬浮宠物 WXPet
#
#  ⭐ 架构铁律：只注入 com.apple.springboard 一个进程。
#     悬浮宠物是「SpringBoard 层的高层级窗口」，天然渲染在所有 App 之上，
#     因此**完全不需要**注入微信或任何目标 App —— 目标 App 只是被盖住的那个。
#     「仅在某些 App 显示」也由 SpringBoard 自己判断前台是谁来实现。
#     这样做的收益：不触碰任何第三方 App 的二进制，不违反其协议，没有封号风险。
# ═══════════════════════════════════════════════════════════════════════

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# ⚠️ roothide 设备必须用 roothide 方案（rootless 打的包会被 Sileo 拒装），
#    且必须使用 roothide/theos 分支的 Theos。
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXPet
WXPet_FILES = Tweak.x WXPCommon.m WXPFrontmost.m WXPetView.m WXPetWindow.m WXPetManager.m
WXPet_CFLAGS = -fobjc-arc -Wall -Wno-unused-function
WXPet_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
