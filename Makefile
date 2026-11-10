TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Ninebot
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NinebotSkin
NinebotSkin_FILES = Tweak.x NBManager.m
NinebotSkin_CFLAGS = -fobjc-arc
# 视频功能不链接 AVFoundation/CoreMedia（头文件仅编译期使用，运行时走 objc_getClass），
# 保持 LC_LOAD_DYLIB 与 v0.1.15（验证可加载）完全一致，避免 tweak 被静默拒载
NinebotSkin_FRAMEWORKS = UIKit Foundation PhotosUI ImageIO
NinebotSkin_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
