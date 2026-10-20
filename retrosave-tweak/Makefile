# App Store 的 App 绝大多数是 arm64（arm64e 主要给系统 App 用），
# 球球大作战属于前者，所以这里只编 arm64 —— 少一个 slice 少一堆 ptrauth 麻烦。
# 万一你的游戏是 arm64e ABI，改成 ARCHS = arm64e 重新编即可。
ARCHS = arm64
TARGET := iphone:clang:latest:15.0

# dopamine / iOS 15+ 越狱默认是 rootless（无根）模式。
# 不加这一行，deb 会把 dylib 装进 /Library/MobileSubstrate/... ，
# 而 rootless 下系统根本不读这个路径 —— 表现为「装成功但按钮不出现」。
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RetroSaveInGame
RetroSaveInGame_FILES = Tweak.xm
RetroSaveInGame_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
RetroSaveInGame_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
