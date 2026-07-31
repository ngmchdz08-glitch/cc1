// CameraHook.x — inject mediaserverd / cameracaptured
// Render: Photo/Video từ file, OBS từ shared memory/IPC với daemon

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.mch.vcam.plist"
#define kOBSFramePath @"/var/mobile/Library/Caches/com.mch.vcam/obs_frame.jpg"

// ─────────────────────────────────────────────────────────────
// MARK: Prefs (read mỗi frame để live-update không cần respring)
// ─────────────────────────────────────────────────────────────
static inline NSDictionary *vcam_prefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
}

// ─────────────────────────────────────────────────────────────
// MARK: CIContext singleton — không tạo mới mỗi frame (expensive)
// ─────────────────────────────────────────────────────────────
static CIContext *sharedCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextWorkingColorSpace: (id)kCFNull,
        }];
    });
    return ctx;
}

// ─────────────────────────────────────────────────────────────
// MARK: Core renderer
// ─────────────────────────────────────────────────────────────
static void vcam_renderIntoBuffer(CVPixelBufferRef pixBuf) {
    if (!pixBuf) return;

    NSDictionary *prefs = vcam_prefs();
    if (![prefs[@"isEnabled"] boolValue]) return;

    NSInteger mode    = [prefs[@"workMode"] integerValue]; // 0=OBS,1=Photo,2=Video
    NSString  *mPath  = prefs[@"mediaPath"];

    // Chọn nguồn ảnh theo mode
    NSString *imgPath = nil;
    if (mode == 0) {
        // OBS mode — daemon ghi frame JPEG vào shared cache
        imgPath = kOBSFramePath;
    } else if ((mode == 1 || mode == 2) && mPath.length > 0) {
        imgPath = mPath;
    }

    if (!imgPath) return;

    // Load ảnh — dùng cache tránh đọc disk mỗi frame với static media
    static NSString *cachedPath;
    static UIImage  *cachedImg;
    UIImage *img = nil;
    if ([imgPath isEqualToString:cachedPath] && cachedImg && mode != 0) {
        img = cachedImg; // static media: dùng cache
    } else {
        img = [UIImage imageWithContentsOfFile:imgPath];
        if (mode != 0) { cachedPath = imgPath; cachedImg = img; }
    }
    if (!img) return;

    size_t w   = CVPixelBufferGetWidth(pixBuf);
    size_t h   = CVPixelBufferGetHeight(pixBuf);
    CGRect rect = CGRectMake(0, 0, w, h);

    CIImage *ci = [[CIImage alloc] initWithCGImage:img.CGImage];
    // Scale to fill (crop center)
    CGFloat scaleX = w / ci.extent.size.width;
    CGFloat scaleY = h / ci.extent.size.height;
    CGFloat scale  = MAX(scaleX, scaleY); // fill, không letterbox
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    // Center crop
    CGFloat dx = (ci.extent.size.width  - w) / 2.0;
    CGFloat dy = (ci.extent.size.height - h) / 2.0;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(-dx, -dy)];

    // Rotation/flip từ prefs
    BOOL hFlip     = [prefs[@"horizontalFlip"] boolValue];
    float rotation = [prefs[@"rotationDegrees"] floatValue];
    if (hFlip)        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    if (rotation != 0) {
        CGFloat rad = rotation * M_PI / 180.0;
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeRotation(rad)];
    }

    CVPixelBufferLockBaseAddress(pixBuf, 0);
    [sharedCIContext() render:ci
               toCVPixelBuffer:pixBuf
                         bounds:rect
                     colorSpace:CGColorSpaceCreateDeviceRGB()];
    CVPixelBufferUnlockBaseAddress(pixBuf, 0);
}

// ─────────────────────────────────────────────────────────────
// MARK: Hooks — 4 BW nodes (mediaserverd camera pipeline)
// ─────────────────────────────────────────────────────────────
%group MediaServerHooks

%hook BWPhotoEncoderNode
- (void)renderSampleBuffer:(CMSampleBufferRef)sbuf forInput:(id)input {
    vcam_renderIntoBuffer(CMSampleBufferGetImageBuffer(sbuf));
    %orig;
}
%end

%hook BWStillImageSampleBufferSinkNode
- (void)renderSampleBuffer:(CMSampleBufferRef)sbuf forInput:(id)input {
    vcam_renderIntoBuffer(CMSampleBufferGetImageBuffer(sbuf));
    %orig;
}
%end

%hook BWImageQueueSinkNode
- (void)renderSampleBuffer:(CMSampleBufferRef)sbuf forInput:(id)input {
    vcam_renderIntoBuffer(CMSampleBufferGetImageBuffer(sbuf));
    %orig;
}
%end

%hook BWRemoteQueueSinkNode
- (void)renderSampleBuffer:(CMSampleBufferRef)sbuf forInput:(id)input {
    vcam_renderIntoBuffer(CMSampleBufferGetImageBuffer(sbuf));
    %orig;
}
%end

%end // MediaServerHooks

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if ([proc isEqualToString:@"mediaserverd"] ||
        [proc isEqualToString:@"cameracaptured"]) {
        %init(MediaServerHooks);
        NSLog(@"[Vcam_Mch/Camera] ACTIVE in %@", proc);
    }
}
