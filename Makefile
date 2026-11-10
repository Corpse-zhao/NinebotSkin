TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Ninebot
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NinebotSkin
NinebotSkin_FILES = Tweak.x NBManager.m
NinebotSkin_CFLAGS = -fobjc-arc
NinebotSkin_FRAMEWORKS = UIKit Foundation PhotosUI ImageIO AVFoundation CoreMedia
NinebotSkin_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
