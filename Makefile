export TARGET = iphone:clang:15.5:15.0
export ARCHS = arm64
export ROOTLESS = 1

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd cameracaptured

include $(THEOS)/makefiles/common.mk

# ─── Tweak 1: Camera hook → mediaserverd / cameracaptured ───
TWEAK_NAME = Vcam_Mch_Camera

Vcam_Mch_Camera_FILES      = CameraHook.x
Vcam_Mch_Camera_CFLAGS     = -fobjc-arc -O2
Vcam_Mch_Camera_FRAMEWORKS = AVFoundation CoreVideo CoreMedia CoreImage UIKit Foundation

# ─── Tweak 2: Overlay → SpringBoard ───────────────────────────
TWEAK_NAME += Vcam_Mch_Overlay

Vcam_Mch_Overlay_FILES     = OverlayHook.x
Vcam_Mch_Overlay_CFLAGS    = -fobjc-arc -O2
Vcam_Mch_Overlay_FRAMEWORKS = UIKit Foundation

# ─── Tweak 3: AntiBank → all user apps ──────────────────────
TWEAK_NAME += Vcam_Mch_AntiBank

Vcam_Mch_AntiBank_FILES    = AntiBank.x
Vcam_Mch_AntiBank_CFLAGS   = -fobjc-arc -O2
Vcam_Mch_AntiBank_FRAMEWORKS = Foundation

# ─── Tweak 4: Main hook + floating panel ──────────────────────
TWEAK_NAME += Vcam_Mch_Main

Vcam_Mch_Main_FILES        = Tweak.x
Vcam_Mch_Main_CFLAGS       = -fobjc-arc -ObjC -O2
Vcam_Mch_Main_FRAMEWORKS   = AVFoundation CoreVideo CoreMedia CoreImage \
                              UIKit Foundation PhotosUI UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += VcamApp VcamDaemon
include $(THEOS_MAKE_PATH)/aggregate.mk
