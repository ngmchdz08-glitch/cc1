export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = VcamStreamDaemon
VcamStreamDaemon_FILES        = main.m
VcamStreamDaemon_CFLAGS       = -fobjc-arc
VcamStreamDaemon_LDFLAGS      = -lz
VcamStreamDaemon_FRAMEWORKS   = Foundation CoreFoundation
VcamStreamDaemon_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
