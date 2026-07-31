// Tweak.x — AVFoundation hook cho TẤT CẢ user-facing apps có camera
// iOS 15+ rootless, iPhone 7 arm64 compatible
// Panel inline — không cần thoát app

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#define kPrefsPath    @"/var/mobile/Library/Preferences/com.mch.vcam.plist"
#define kOBSFramePath @"/var/mobile/Library/Caches/com.mch.vcam/obs_frame.jpg"
#define kCacheDir     @"/var/mobile/Library/Caches/com.mch.vcam"

// ─────────────────────────────────────────────────────────────
// MARK: Shared helpers
// ─────────────────────────────────────────────────────────────
static NSDictionary *vcam_prefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
}
static void vcam_savePrefs(NSMutableDictionary *p) {
    [p writeToFile:kPrefsPath atomically:YES];
}
static BOOL vcam_enabled(void) {
    NSDictionary *p = vcam_prefs();
    return p[@"isEnabled"] ? [p[@"isEnabled"] boolValue] : YES;
}

static CIContext *vcam_ciCtx(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ctx;
}

// ─────────────────────────────────────────────────────────────
// MARK: Build fake CMSampleBuffer từ ảnh/OBS frame
// ─────────────────────────────────────────────────────────────
static CMSampleBufferRef vcam_fakeSampleBuffer(CMSampleBufferRef orig) {
    if (!orig || !vcam_enabled()) return NULL;

    CVPixelBufferRef origPix = CMSampleBufferGetImageBuffer(orig);
    if (!origPix) return NULL;

    NSDictionary *prefs = vcam_prefs();
    NSInteger mode  = [prefs[@"workMode"] integerValue];
    NSString *mPath = prefs[@"mediaPath"];

    NSString *imgPath = nil;
    if (mode == 0)                                     imgPath = kOBSFramePath;
    else if ((mode == 1 || mode == 2) && mPath.length) imgPath = mPath;
    if (!imgPath) return NULL;

    // Static media cache (không reload disk mỗi frame)
    static NSString *cachedPath;
    static UIImage  *cachedImg;
    UIImage *img = nil;
    if (mode != 0 && [imgPath isEqualToString:cachedPath] && cachedImg) {
        img = cachedImg;
    } else {
        img = [UIImage imageWithContentsOfFile:imgPath];
        if (mode != 0) { cachedPath = imgPath; cachedImg = img; }
    }
    if (!img) return NULL;

    size_t w   = CVPixelBufferGetWidth(origPix);
    size_t h   = CVPixelBufferGetHeight(origPix);
    OSType fmt = CVPixelBufferGetPixelFormatType(origPix);

    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef newPix = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                            (__bridge CFDictionaryRef)attrs, &newPix) != kCVReturnSuccess) {
        return NULL;
    }

    CIImage *ci = [[CIImage alloc] initWithCGImage:img.CGImage];
    CGFloat sx  = (CGFloat)w / ci.extent.size.width;
    CGFloat sy  = (CGFloat)h / ci.extent.size.height;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(MAX(sx,sy), MAX(sx,sy))];
    CGFloat dx  = (ci.extent.size.width  - (CGFloat)w) / 2.0;
    CGFloat dy  = (ci.extent.size.height - (CGFloat)h) / 2.0;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(-dx, -dy)];

    BOOL flip      = [prefs[@"horizontalFlip"] boolValue];
    float rotation = [prefs[@"rotationDegrees"] floatValue];
    if (flip)        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    if (rotation != 0)
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeRotation(rotation * M_PI / 180.0)];

    CVPixelBufferLockBaseAddress(newPix, 0);
    [vcam_ciCtx() render:ci toCVPixelBuffer:newPix
                   bounds:CGRectMake(0, 0, w, h)
               colorSpace:CGColorSpaceCreateDeviceRGB()];
    CVPixelBufferUnlockBaseAddress(newPix, 0);

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    CMSampleBufferGetSampleTimingInfo(orig, 0, &timing);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newPix, &fmtDesc);

    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, newPix,
                                       YES, NULL, NULL, fmtDesc, &timing, &result);
    if (fmtDesc) CFRelease(fmtDesc);
    CVPixelBufferRelease(newPix);
    return result;
}

// ─────────────────────────────────────────────────────────────
// MARK: Get key window (iOS 13+ safe)
// ─────────────────────────────────────────────────────────────
static UIWindow *vcam_keyWindow(void) {
    // iOS 15 compatible
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            return ws.windows.firstObject;
        }
    }
    return nil;
}

static UIViewController *vcam_topVC(void) {
    UIViewController *vc = vcam_keyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}


// ─────────────────────────────────────────────────────────────
// MARK: Floating Panel
// ─────────────────────────────────────────────────────────────
@interface VcamFloatingPanel : UIView <PHPickerViewControllerDelegate>

@property (nonatomic, strong) UIButton           *triggerBtn;
@property (nonatomic, strong) UIView             *panelView;
@property (nonatomic, strong) UILabel            *statusLbl;
@property (nonatomic, strong) UIButton           *toggleBtn;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UITextField        *obsIPField;
@property (nonatomic, strong) UILabel            *obsModeLabel;
@property (nonatomic, assign) BOOL               panelOpen;
@property (nonatomic, strong) NSMutableDictionary *prefs;

+ (instancetype)sharedPanel;
- (void)attachToWindow:(UIWindow *)window;
- (void)refreshState;

@end

@implementation VcamFloatingPanel

+ (instancetype)sharedPanel {
    static VcamFloatingPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[VcamFloatingPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
                     ?: [NSMutableDictionary dictionary];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    // ─── Trigger button ───
    CGFloat btnS = 54;
    self.triggerBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.triggerBtn.frame = CGRectMake(0, 0, btnS, btnS);
    self.triggerBtn.layer.cornerRadius = btnS / 2;
    self.triggerBtn.clipsToBounds = YES;
    self.triggerBtn.layer.borderWidth = 2;
    self.triggerBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;

    // Dark purple gradient
    CAGradientLayer *tg = [CAGradientLayer layer];
    tg.frame = self.triggerBtn.bounds;
    tg.colors = @[(id)[UIColor colorWithRed:0.08 green:0.08 blue:0.22 alpha:0.96].CGColor,
                  (id)[UIColor colorWithRed:0.18 green:0.06 blue:0.32 alpha:0.96].CGColor];
    tg.cornerRadius = btnS / 2;
    [self.triggerBtn.layer insertSublayer:tg atIndex:0];

    // SF Symbol icon
    UIImageView *ico = [[UIImageView alloc] initWithFrame:CGRectMake(10, 10, 34, 34)];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    ico.image = [UIImage systemImageNamed:@"camera.fill" withConfiguration:cfg];
    ico.tintColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1];
    ico.contentMode = UIViewContentModeScaleAspectFit;
    [self.triggerBtn addSubview:ico];

    [self.triggerBtn addTarget:self action:@selector(togglePanel)
              forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handlePan:)];
    [self.triggerBtn addGestureRecognizer:pan];

    // ─── Panel view ───
    CGFloat pw = 296, ph = 430;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    self.panelView.hidden = YES;
    self.panelView.alpha  = 0;
    self.panelView.layer.cornerRadius = 20;
    self.panelView.layer.masksToBounds = YES;
    self.panelView.layer.borderWidth = 0.5;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;

    // Blur
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:blur];
    bv.frame = CGRectMake(0, 0, pw, ph);
    [self.panelView addSubview:bv];

    // Gradient overlay
    CAGradientLayer *pg = [CAGradientLayer layer];
    pg.frame  = CGRectMake(0, 0, pw, ph);
    pg.colors = @[(id)[UIColor colorWithRed:0.04 green:0.04 blue:0.15 alpha:0.72].CGColor,
                  (id)[UIColor colorWithRed:0.10 green:0.03 blue:0.22 alpha:0.60].CGColor];
    [self.panelView.layer addSublayer:pg];

    CGFloat mx = 14, cy = 18;

    // Header
    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(mx, cy, pw - mx*2 - 36, 26)];
    hdr.text = @"VCAM MCH";
    hdr.font = [UIFont boldSystemFontOfSize:17];
    hdr.textColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1];
    [self.panelView addSubview:hdr];

    UIButton *xBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    xBtn.frame = CGRectMake(pw - 42, cy - 2, 32, 32);
    [xBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    xBtn.tintColor = [UIColor colorWithWhite:0.5 alpha:1];
    [xBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:xBtn];
    cy += 36;

    // Divider
    UIView *dv = [[UIView alloc] initWithFrame:CGRectMake(mx, cy, pw - mx*2, 0.5)];
    dv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    [self.panelView addSubview:dv];
    cy += 10;

    // Toggle button
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleBtn.frame = CGRectMake(mx, cy, pw - mx*2, 44);
    self.toggleBtn.layer.cornerRadius = 11;
    self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.toggleBtn addTarget:self action:@selector(tapToggle)
             forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:self.toggleBtn];
    cy += 54;

    // Status
    self.statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(mx, cy, pw - mx*2, 16)];
    self.statusLbl.font = [UIFont systemFontOfSize:10.5];
    self.statusLbl.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    self.statusLbl.textAlignment = NSTextAlignmentCenter;
    self.statusLbl.adjustsFontSizeToFitWidth = YES;
    [self.panelView addSubview:self.statusLbl];
    cy += 26;

    // Mode segmented
    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"OBS", @"Ảnh", @"Video"]];
    self.modeSeg.frame = CGRectMake(mx, cy, pw - mx*2, 34);
    self.modeSeg.selectedSegmentTintColor = [UIColor colorWithRed:0.28 green:0.55 blue:0.95 alpha:0.9];
    [self.modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}
                                forState:UIControlStateNormal];
    [self.modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}
                                forState:UIControlStateSelected];
    [self.modeSeg addTarget:self action:@selector(modeChanged:)
           forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.modeSeg];
    cy += 44;

    // OBS IP row
    self.obsModeLabel = [[UILabel alloc] initWithFrame:CGRectMake(mx, cy + 5, 52, 16)];
    self.obsModeLabel.text = @"OBS IP:";
    self.obsModeLabel.font = [UIFont boldSystemFontOfSize:10.5];
    self.obsModeLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    [self.panelView addSubview:self.obsModeLabel];

    self.obsIPField = [[UITextField alloc] initWithFrame:CGRectMake(mx + 58, cy, pw - mx*2 - 58, 30)];
    self.obsIPField.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.obsIPField.textColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1];
    self.obsIPField.keyboardType = UIKeyboardTypeDecimalPad;
    self.obsIPField.returnKeyType = UIReturnKeyDone;
    self.obsIPField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.obsIPField.layer.cornerRadius = 8;
    self.obsIPField.layer.borderWidth = 0.5;
    self.obsIPField.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    self.obsIPField.textAlignment = NSTextAlignmentCenter;
    UIView *lpad = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
    self.obsIPField.leftView = lpad;
    self.obsIPField.leftViewMode = UITextFieldViewModeAlways;
    [self.obsIPField addTarget:self action:@selector(obsIPDone)
              forControlEvents:UIControlEventEditingDidEndOnExit];
    [self.panelView addSubview:self.obsIPField];
    cy += 40;

    // RTMP hint
    UILabel *rtmpHint = [[UILabel alloc] initWithFrame:CGRectMake(mx, cy, pw - mx*2, 14)];
    rtmpHint.text = @"RTMP: rtmp://<IP>:1935/live/vcam";
    rtmpHint.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightLight];
    rtmpHint.textColor = [UIColor colorWithWhite:0.35 alpha:1];
    rtmpHint.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:rtmpHint];
    cy += 22;

    // Pick file button
    UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    pickBtn.frame = CGRectMake(mx, cy, pw - mx*2, 40);
    pickBtn.layer.cornerRadius = 10;
    pickBtn.layer.borderWidth = 1;
    pickBtn.layer.borderColor = [UIColor colorWithRed:0.3 green:0.75 blue:1 alpha:0.4].CGColor;
    pickBtn.backgroundColor = [UIColor colorWithRed:0.08 green:0.25 blue:0.45 alpha:0.4];
    [pickBtn setTitle:@"  CHỌN ẢNH / VIDEO" forState:UIControlStateNormal];
    UIImageSymbolConfiguration *cfg2 = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [pickBtn setImage:[UIImage systemImageNamed:@"photo.on.rectangle.angled" withConfiguration:cfg2]
             forState:UIControlStateNormal];
    pickBtn.tintColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1];
    pickBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [pickBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [pickBtn addTarget:self action:@selector(pickMedia) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:pickBtn];
    cy += 50;

    // Flip + Rotate row
    CGFloat hw = (pw - mx*2 - 8) / 2;
    UIButton *flipBtn = [self makeSmallBtn:@"Lật ngang" icon:@"arrow.left.and.right"];
    flipBtn.frame = CGRectMake(mx, cy, hw, 34);
    [flipBtn addTarget:self action:@selector(tapFlip) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:flipBtn];

    UIButton *rotBtn = [self makeSmallBtn:@"Xoay 90°" icon:@"rotate.right"];
    rotBtn.frame = CGRectMake(mx + hw + 8, cy, hw, 34);
    [rotBtn addTarget:self action:@selector(tapRotate) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:rotBtn];

    [self refreshState];
}

- (UIButton *)makeSmallBtn:(NSString *)title icon:(NSString *)iconName {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.layer.cornerRadius = 9;
    btn.layer.borderWidth = 0.5;
    btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:12
                                                                                    weight:UIImageSymbolWeightMedium];
    [btn setImage:[UIImage systemImageNamed:iconName withConfiguration:c] forState:UIControlStateNormal];
    [btn setTitle:[NSString stringWithFormat:@" %@", title] forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:0.85 alpha:1] forState:UIControlStateNormal];
    btn.tintColor = [UIColor colorWithWhite:0.75 alpha:1];
    btn.titleLabel.font = [UIFont systemFontOfSize:11];
    return btn;
}

- (void)attachToWindow:(UIWindow *)window {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    self.triggerBtn.center = CGPointMake(screen.width - 34, 200);
    [window addSubview:self.triggerBtn];
    [window addSubview:self.panelView];
    // Bring to front
    [window bringSubviewToFront:self.triggerBtn];
    [window bringSubviewToFront:self.panelView];
}

- (void)togglePanel {
    self.panelOpen = !self.panelOpen;
    if (self.panelOpen) {
        [self refreshState];
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGFloat pw = self.panelView.bounds.size.width;
        CGFloat ph = self.panelView.bounds.size.height;
        CGPoint tc = self.triggerBtn.center;
        CGFloat px = (tc.x > screen.width / 2) ? tc.x - pw - 8 : tc.x + 32;
        CGFloat py = MIN(MAX(tc.y - 60, 60), screen.height - ph - 40);
        self.panelView.frame = CGRectMake(px, py, pw, ph);
        self.panelView.hidden = NO;
        self.panelView.transform = CGAffineTransformMakeScale(0.88, 0.88);
        [UIView animateWithDuration:0.26 delay:0
             usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.panelView.alpha = 1;
            self.panelView.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.18 animations:^{
            self.panelView.alpha = 0;
            self.panelView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL done) {
            self.panelView.hidden = YES;
            self.panelView.transform = CGAffineTransformIdentity;
        }];
    }
}

- (void)refreshState {
    self.prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
                 ?: [NSMutableDictionary dictionary];
    BOOL on        = [self.prefs[@"isEnabled"] boolValue];
    NSInteger mode = [self.prefs[@"workMode"] integerValue];
    NSString *ip   = self.prefs[@"obsIP"] ?: @"?";
    NSString *mp   = self.prefs[@"mediaPath"];

    if (on) {
        self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.68 blue:0.38 alpha:0.92];
        [self.toggleBtn setTitle:@"● ĐANG BẬT  —  Nhấn để TẮT" forState:UIControlStateNormal];
        [self.toggleBtn setTitleColor:[UIColor colorWithRed:0.8 green:1 blue:0.87 alpha:1] forState:UIControlStateNormal];
    } else {
        self.toggleBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.85];
        [self.toggleBtn setTitle:@"○ ĐANG TẮT  —  Nhấn để BẬT" forState:UIControlStateNormal];
        [self.toggleBtn setTitleColor:[UIColor colorWithWhite:0.52 alpha:1] forState:UIControlStateNormal];
    }

    self.triggerBtn.layer.borderColor = on
        ? [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:0.85].CGColor
        : [UIColor colorWithWhite:0.35 alpha:0.7].CGColor;

    self.modeSeg.selectedSegmentIndex = (NSInteger)MIN(mode, 2);
    self.obsIPField.text = self.prefs[@"obsIP"] ?: @"192.168.x.x";

    BOOL obsMode = (mode == 0);
    self.obsModeLabel.alpha = obsMode ? 1.0 : 0.3;
    self.obsIPField.alpha   = obsMode ? 1.0 : 0.3;

    if (mode == 0)
        self.statusLbl.text = [NSString stringWithFormat:@"rtmp://%@:1935/live/vcam", ip];
    else if (mp.length)
        self.statusLbl.text = mp.lastPathComponent;
    else
        self.statusLbl.text = @"Chưa chọn file";
}

// ─── Actions ───
- (void)tapToggle {
    BOOL cur = [self.prefs[@"isEnabled"] boolValue];
    self.prefs[@"isEnabled"] = @(!cur);
    vcam_savePrefs(self.prefs);
    [self refreshState];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc]
                                        initWithStyle:UIImpactFeedbackStyleMedium];
        [h impactOccurred];
    }
}

- (void)modeChanged:(UISegmentedControl *)seg {
    self.prefs[@"workMode"] = @(seg.selectedSegmentIndex);
    vcam_savePrefs(self.prefs);
    [self refreshState];
}

- (void)obsIPDone {
    if (self.obsIPField.text.length) {
        self.prefs[@"obsIP"] = self.obsIPField.text;
        vcam_savePrefs(self.prefs);
        [self refreshState];
    }
    [self.obsIPField resignFirstResponder];
}

- (void)tapFlip {
    BOOL cur = [self.prefs[@"horizontalFlip"] boolValue];
    self.prefs[@"horizontalFlip"] = @(!cur);
    vcam_savePrefs(self.prefs);
}

- (void)tapRotate {
    float cur = [self.prefs[@"rotationDegrees"] floatValue];
    self.prefs[@"rotationDegrees"] = @(fmod(cur + 90.0f, 360.0f));
    vcam_savePrefs(self.prefs);
}

- (void)pickMedia {
    UIViewController *topVC = vcam_topVC();
    if (!topVC) return;

    NSInteger mode = [self.prefs[@"workMode"] integerValue];
    if (mode == 0) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"OBS IP"
            message:@"Nhập IP máy tính chạy OBS\n(cùng WiFi với iPhone)"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder  = @"192.168.x.x";
            tf.text         = self.prefs[@"obsIP"] ?: @"";
            tf.keyboardType = UIKeyboardTypeDecimalPad;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *ip = a.textFields.firstObject.text;
            if (ip.length) { self.prefs[@"obsIP"] = ip; vcam_savePrefs(self.prefs); [self refreshState]; }
        }]];
        [topVC presentViewController:a animated:YES completion:nil];
        return;
    }

    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1;
    cfg.filter = (mode == 2) ? [PHPickerFilter videosFilter] : [PHPickerFilter imagesFilter];
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [topVC presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;

    PHPickerResult *r = results.firstObject;
    NSInteger mode = [self.prefs[@"workMode"] integerValue];
    NSString *uti  = (mode == 2) ? UTTypeMovie.identifier : UTTypeImage.identifier;

    [r.itemProvider loadFileRepresentationForTypeIdentifier:uti
                                         completionHandler:^(NSURL *url, NSError *err) {
        if (!url) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:kCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dst = [kCacheDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"media_%@", url.lastPathComponent]];
        [fm removeItemAtPath:dst error:nil];
        [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.prefs[@"mediaPath"] = dst;
            vcam_savePrefs(self.prefs);
            [self refreshState];
        });
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint d = [pan translationInView:v.superview];
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat r = v.bounds.size.width / 2.0;
    CGPoint c = CGPointMake(
        MAX(r + 4, MIN(screen.width  - r - 4, v.center.x + d.x)),
        MAX(r + 28, MIN(screen.height - r - 28, v.center.y + d.y))
    );
    v.center = c;
    [pan setTranslation:CGPointZero inView:v.superview];
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat snap = c.x < screen.width/2 ? r + 4 : screen.width - r - 4;
        [UIView animateWithDuration:0.3 delay:0
             usingSpringWithDamping:0.72 initialSpringVelocity:0.5
                            options:0 animations:^{ v.center = CGPointMake(snap, c.y); }
                         completion:nil];
    }
}

@end


// ─────────────────────────────────────────────────────────────
// MARK: AVFoundation Hooks (single %group, no duplicate)
// ─────────────────────────────────────────────────────────────
%group AVFoundationHooks

// Hook frame output cho mọi camera app
%hook AVCaptureVideoDataOutput
- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (vcam_enabled()) {
        CMSampleBufferRef fake = vcam_fakeSampleBuffer(sampleBuffer);
        if (fake) {
            %orig(output, fake, connection);
            CFRelease(fake);
            return;
        }
    }
    %orig;
}
%end

// Auto-attach panel khi app mở camera
%hook AVCaptureSession
- (void)startRunning {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *kw = vcam_keyWindow();
        if (!kw) return;
        VcamFloatingPanel *panel = [VcamFloatingPanel sharedPanel];
        if (!panel.triggerBtn.superview) {
            [panel attachToWindow:kw];
        }
    });
}
%end

%end // AVFoundationHooks


// ─────────────────────────────────────────────────────────────
// MARK: Constructor
// ─────────────────────────────────────────────────────────────
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    // Chỉ inject vào user-facing apps, bỏ qua hệ thống
    NSArray *skip = @[@"mediaserverd", @"cameracaptured", @"SpringBoard",
                      @"launchd", @"configd", @"powerd", @"backboardd",
                      @"aggregated", @"syslogd", @"notifyd", @"logd"];
    if (![skip containsObject:proc]) {
        %init(AVFoundationHooks);
        NSLog(@"[Vcam_Mch] Hooks ACTIVE in: %@", proc);
    }
}
