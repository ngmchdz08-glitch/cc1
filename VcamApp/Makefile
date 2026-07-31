export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VcamApp
VcamApp_FILES              = main.m VcamRootViewController.m VcamAppDelegate.m
VcamApp_FRAMEWORKS         = UIKit CoreGraphics Foundation PhotosUI UniformTypeIdentifiers
VcamApp_CFLAGS             = -fobjc-arc -ObjC
VcamApp_CODESIGN_FLAGS     = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
