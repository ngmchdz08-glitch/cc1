// OverlayHook.x — inject vào SpringBoard
// Mirror VCNextOverlay.dylib: floating button, drag, toggle, IOSurface-safe window

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kPrefsPath   = @"/var/mobile/Library/Preferences/com.mch.vcam.plist";
static NSString *const kWindowKey   = @"vcam_overlayWindow";
static NSString *const kButtonKey   = @"vcam_floatingBtn";

// ─────────────────────────────────────────────
// MARK: Pass-through window (không ăn cảm ứng nền)
// ─────────────────────────────────────────────
%subclass VcamOverlayWindow : UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    // Chỉ cho phép cảm ứng khi chạm trúng button con, không phải window
    return (hit == self) ? nil : hit;
}
%end

// ─────────────────────────────────────────────
// MARK: Helpers
// ─────────────────────────────────────────────
static NSDictionary *overlay_readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
}

static void overlay_syncButtonState(UIButton *btn) {
    NSDictionary *prefs = overlay_readPrefs();
    BOOL on = prefs[@"isEnabled"] ? [prefs[@"isEnabled"] boolValue] : YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (on) {
            btn.backgroundColor = [UIColor colorWithRed:0.9 green:0.15 blue:0.15 alpha:0.92];
            [btn setTitle:@"CAM\nON" forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.92];
            [btn setTitle:@"CAM\nOFF" forState:UIControlStateNormal];
        }
    });
}

// ─────────────────────────────────────────────
// MARK: SpringBoard hook
// ─────────────────────────────────────────────
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Window đè lên mọi thứ — dùng %c() để lấy runtime class đã subclassed
        UIWindow *overlayWindow = [[%c(VcamOverlayWindow) alloc]
                                   initWithFrame:[UIScreen mainScreen].bounds];
        overlayWindow.windowLevel   = UIWindowLevelStatusBar + 1000.0;
        overlayWindow.hidden        = NO;
        overlayWindow.backgroundColor = [UIColor clearColor];
        // Quan trọng: phải có rootViewController để window không bị dismiss
        overlayWindow.rootViewController = [[UIViewController alloc] init];

        // --- Floating button ---
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame              = CGRectMake(12, 160, 58, 58);
        btn.layer.cornerRadius = 29;
        btn.clipsToBounds      = YES;
        btn.titleLabel.font    = [UIFont boldSystemFontOfSize:11];
        btn.titleLabel.numberOfLines   = 2;
        btn.titleLabel.textAlignment   = NSTextAlignmentCenter;
        btn.titleLabel.adjustsFontSizeToFitWidth = YES;
        btn.layer.shadowColor  = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.5;
        btn.layer.shadowRadius  = 5;
        btn.layer.shadowOffset  = CGSizeMake(0, 3);

        overlay_syncButtonState(btn);

        // Pan drag
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(vcam_handlePan:)];
        [btn addGestureRecognizer:pan];

        // Tap toggle
        [btn addTarget:self
                action:@selector(vcam_toggleCam:)
      forControlEvents:UIControlEventTouchUpInside];

        [overlayWindow addSubview:btn];

        // Giữ reference — window và button không bị ARC hủy
        objc_setAssociatedObject(self, kWindowKey.UTF8String, overlayWindow,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kButtonKey.UTF8String, btn,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// ─────────────────────────────────────────────
// MARK: Pan gesture — drag button khắp màn hình
// ─────────────────────────────────────────────
%new
- (void)vcam_handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *btn = recognizer.view;
    CGPoint delta = [recognizer translationInView:btn.superview];
    
    CGPoint newCenter = CGPointMake(btn.center.x + delta.x,
                                    btn.center.y + delta.y);
    
    // Clamp vào màn hình
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat r = btn.bounds.size.width / 2.0;
    newCenter.x = MAX(r, MIN(screen.width  - r, newCenter.x));
    newCenter.y = MAX(r + 20, MIN(screen.height - r - 20, newCenter.y));
    
    btn.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:btn.superview];
    
    // Snapping về cạnh khi thả
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        CGFloat targetX = (newCenter.x < screen.width / 2.0)
            ? r + 4
            : screen.width - r - 4;
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            btn.center = CGPointMake(targetX, newCenter.y);
        } completion:nil];
    }
}

// ─────────────────────────────────────────────
// MARK: Toggle — bật/tắt + sync prefs
// ─────────────────────────────────────────────
%new
- (void)vcam_toggleCam:(UIButton *)sender {
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
        ?: [NSMutableDictionary dictionary];
    
    BOOL current = [prefs[@"isEnabled"] boolValue];
    BOOL next    = !current;
    prefs[@"isEnabled"] = @(next);
    [prefs writeToFile:kPrefsPath atomically:YES];
    
    overlay_syncButtonState(sender);
    
    // Haptic feedback nhẹ
    UISelectionFeedbackGenerator *haptic = [[UISelectionFeedbackGenerator alloc] init];
    [haptic prepare];
    [haptic selectionChanged];
}

%end // SpringBoard

// ─────────────────────────────────────────────
// MARK: Constructor
// ─────────────────────────────────────────────
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if ([proc isEqualToString:@"SpringBoard"]) {
        %init;
        NSLog(@"[Vcam_Mch/Overlay] SpringBoard hooks ACTIVE");
    }
}
