// VcamRootViewController.m — fixed version
// Removed lbl.letterSpacing (not a UILabel property)
// Added objc/runtime import for objc_setAssociatedObject

#import "VcamRootViewController.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#define kPrefsPath @"/var/mobile/Library/Preferences/com.mch.vcam.plist"
#define kCacheDir  @"/var/mobile/Library/Caches/com.mch.vcam"

// ─────────────────────────────────────────────────────────────
// Gradient button factory
// ─────────────────────────────────────────────────────────────
static UIButton *makeGradBtn(NSString *title, NSString *iconName,
                              UIColor *c1, UIColor *c2) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.layer.cornerRadius = 13;
    btn.clipsToBounds = YES;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    if (iconName) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:iconName withConfiguration:cfg];
        [btn setImage:img forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 6);
        btn.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
    }
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors     = @[(id)c1.CGColor, (id)c2.CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint   = CGPointMake(1, 1);
    g.cornerRadius = 13;
    [btn.layer insertSublayer:g atIndex:0];
    objc_setAssociatedObject(btn, "gradLayer", g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return btn;
}

@interface VcamRootViewController ()
@property (nonatomic, strong) NSMutableDictionary *prefs;
@property (nonatomic, strong) UIView              *headerView;
@property (nonatomic, strong) UISwitch            *masterSwitch;
@property (nonatomic, strong) UILabel             *statusLabel;
@property (nonatomic, strong) UISegmentedControl  *modeSeg;
@property (nonatomic, strong) UIView              *obsCard;
@property (nonatomic, strong) UITextField         *obsIPField;
@property (nonatomic, strong) UILabel             *rtmpLabel;
@property (nonatomic, strong) UILabel             *daemonStatusLabel;
@property (nonatomic, strong) UIView              *fileCard;
@property (nonatomic, strong) UILabel             *fileNameLabel;
@property (nonatomic, strong) UISlider            *rotateSlider;
@property (nonatomic, strong) UILabel             *rotateValueLabel;
@property (nonatomic, strong) UISwitch            *flipSwitch;
@property (nonatomic, strong) NSTimer             *refreshTimer;
@end

@implementation VcamRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadPrefs];
    [self buildUI];
    [self refreshUI];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                         target:self
                                                       selector:@selector(refreshUI)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CAGradientLayer *hg = (CAGradientLayer *)self.headerView.layer.sublayers.firstObject;
    if ([hg isKindOfClass:[CAGradientLayer class]]) hg.frame = self.headerView.bounds;
}

- (void)loadPrefs {
    self.prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath]
                 ?: [NSMutableDictionary dictionary];
}
- (void)savePrefs {
    [self.prefs writeToFile:kPrefsPath atomically:YES];
}

- (void)buildUI {
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.09 alpha:1];
    CGFloat W = self.view.bounds.size.width;
    CGFloat mx = 16;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:scroll];

    CGFloat y = 0;

    // ── Header ──
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 188)];
    CAGradientLayer *hg = [CAGradientLayer layer];
    hg.frame  = self.headerView.bounds;
    hg.colors = @[(id)[UIColor colorWithRed:0.10 green:0.07 blue:0.30 alpha:1].CGColor,
                  (id)[UIColor colorWithRed:0.04 green:0.04 blue:0.09 alpha:1].CGColor];
    [self.headerView.layer addSublayer:hg];
    [scroll addSubview:self.headerView];

    UIImageView *ico = [[UIImageView alloc] initWithFrame:CGRectMake(mx, 46, 50, 50)];
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration
        configurationWithPointSize:28 weight:UIImageSymbolWeightMedium];
    ico.image = [UIImage systemImageNamed:@"camera.fill" withConfiguration:c];
    ico.tintColor = [UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:1];
    ico.contentMode = UIViewContentModeCenter;
    [self.headerView addSubview:ico];

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(mx + 58, 48, W - mx*2 - 58, 30)];
    tl.text = @"VCAM MCH";
    tl.font = [UIFont boldSystemFontOfSize:27];
    tl.textColor = [UIColor whiteColor];
    [self.headerView addSubview:tl];

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(mx + 58, 80, W - mx*2 - 58, 18)];
    sl.text = @"Virtual Camera · OBS · Photo · Video";
    sl.font = [UIFont systemFontOfSize:12];
    sl.textColor = [UIColor colorWithWhite:0.50 alpha:1];
    [self.headerView addSubview:sl];

    // Master toggle row
    UIView *toggleRow = [[UIView alloc] initWithFrame:CGRectMake(mx, 114, W - mx*2, 46)];
    toggleRow.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    toggleRow.layer.cornerRadius = 12;
    [self.headerView addSubview:toggleRow];

    UILabel *trl = [[UILabel alloc] initWithFrame:CGRectMake(14, 11, 220, 24)];
    trl.text = @"Kích hoạt Virtual Camera";
    trl.font = [UIFont boldSystemFontOfSize:14];
    trl.textColor = [UIColor whiteColor];
    [toggleRow addSubview:trl];

    self.masterSwitch = [[UISwitch alloc] init];
    CGSize swSize = self.masterSwitch.frame.size;
    self.masterSwitch.frame = CGRectMake(toggleRow.bounds.size.width - swSize.width - 14,
                                         (46 - swSize.height)/2, swSize.width, swSize.height);
    self.masterSwitch.onTintColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.44 alpha:1];
    [self.masterSwitch addTarget:self action:@selector(masterToggled:)
                forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:self.masterSwitch];

    y = 196;

    // Status
    y = [self card:scroll y:y mx:mx W:W h:50 block:^(UIView *card) {
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(card.bounds, 12, 8)];
        self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightMedium];
        self.statusLabel.textColor = [UIColor colorWithRed:0.35 green:0.85 blue:1 alpha:1];
        self.statusLabel.numberOfLines = 2;
        self.statusLabel.adjustsFontSizeToFitWidth = YES;
        [card addSubview:self.statusLabel];
    }];

    // Mode
    y = [self sectionLbl:scroll y:y mx:mx text:@"NGUỒN CAMERA"];
    y = [self card:scroll y:y mx:mx W:W h:58 block:^(UIView *card) {
        self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"OBS Stream", @"Ảnh", @"Video"]];
        self.modeSeg.frame = CGRectInset(card.bounds, 12, 11);
        self.modeSeg.selectedSegmentTintColor = [UIColor colorWithRed:0.24 green:0.54 blue:0.95 alpha:0.9];
        [self.modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}
                                    forState:UIControlStateNormal];
        [self.modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}
                                    forState:UIControlStateSelected];
        [self.modeSeg addTarget:self action:@selector(modeChanged:)
               forControlEvents:UIControlEventValueChanged];
        [card addSubview:self.modeSeg];
    }];

    // OBS
    y = [self sectionLbl:scroll y:y mx:mx text:@"CẤU HÌNH OBS"];
    y = [self card:scroll y:y mx:mx W:W h:108 block:^(UIView *card) {
        self.obsCard = card;
        CGFloat cw = card.bounds.size.width;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, 58, 18)];
        lbl.text = @"OBS IP:"; lbl.font = [UIFont boldSystemFontOfSize:12];
        lbl.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        [card addSubview:lbl];

        self.obsIPField = [[UITextField alloc] initWithFrame:CGRectMake(78, 8, cw - 92, 32)];
        self.obsIPField.placeholder = @"192.168.x.x";
        self.obsIPField.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
        self.obsIPField.textColor = [UIColor colorWithRed:0.35 green:0.88 blue:1 alpha:1];
        self.obsIPField.keyboardType = UIKeyboardTypeDecimalPad;
        self.obsIPField.returnKeyType = UIReturnKeyDone;
        self.obsIPField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        self.obsIPField.layer.cornerRadius = 8;
        self.obsIPField.layer.borderWidth = 0.5;
        self.obsIPField.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        self.obsIPField.textAlignment = NSTextAlignmentCenter;
        UIView *lv = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
        self.obsIPField.leftView = lv; self.obsIPField.leftViewMode = UITextFieldViewModeAlways;
        [self.obsIPField addTarget:self action:@selector(saveOBSIP)
                  forControlEvents:UIControlEventEditingDidEndOnExit];
        [card addSubview:self.obsIPField];

        self.rtmpLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 48, cw - 28, 18)];
        self.rtmpLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightLight];
        self.rtmpLabel.textColor = [UIColor colorWithWhite:0.38 alpha:1];
        self.rtmpLabel.adjustsFontSizeToFitWidth = YES;
        [card addSubview:self.rtmpLabel];

        self.daemonStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 68, cw - 28, 30)];
        self.daemonStatusLabel.font = [UIFont systemFontOfSize:10];
        self.daemonStatusLabel.textColor = [UIColor colorWithWhite:0.42 alpha:1];
        self.daemonStatusLabel.numberOfLines = 2;
        [card addSubview:self.daemonStatusLabel];
    }];

    // File
    y = [self sectionLbl:scroll y:y mx:mx text:@"CHỌN FILE NGUỒN"];
    y = [self card:scroll y:y mx:mx W:W h:86 block:^(UIView *card) {
        self.fileCard = card;
        CGFloat cw = card.bounds.size.width;

        self.fileNameLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cw - 28, 18)];
        self.fileNameLabel.text = @"Chưa chọn file";
        self.fileNameLabel.font = [UIFont systemFontOfSize:12];
        self.fileNameLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        self.fileNameLabel.textAlignment = NSTextAlignmentCenter;
        [card addSubview:self.fileNameLabel];

        UIButton *pb = makeGradBtn(@"CHỌN ẢNH / VIDEO", @"photo.badge.plus",
                                   [UIColor colorWithRed:0.10 green:0.32 blue:0.80 alpha:1],
                                   [UIColor colorWithRed:0.28 green:0.08 blue:0.70 alpha:1]);
        pb.frame = CGRectMake(14, 32, cw - 28, 42);
        CAGradientLayer *pg = objc_getAssociatedObject(pb, "gradLayer");
        pg.frame = pb.bounds;
        [pb addTarget:self action:@selector(pickMedia) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:pb];
    }];

    // Adjust
    y = [self sectionLbl:scroll y:y mx:mx text:@"ĐIỀU CHỈNH"];
    y = [self card:scroll y:y mx:mx W:W h:126 block:^(UIView *card) {
        CGFloat cw = card.bounds.size.width;

        UILabel *fl = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, 160, 20)];
        fl.text = @"Lật ngang (Mirror)";
        fl.font = [UIFont systemFontOfSize:13]; fl.textColor = [UIColor whiteColor];
        [card addSubview:fl];

        self.flipSwitch = [[UISwitch alloc] init];
        CGSize fsz = self.flipSwitch.frame.size;
        self.flipSwitch.frame = CGRectMake(cw - fsz.width - 14, 10, fsz.width, fsz.height);
        self.flipSwitch.onTintColor = [UIColor colorWithRed:0.24 green:0.54 blue:0.95 alpha:1];
        [self.flipSwitch addTarget:self action:@selector(flipToggled:)
                  forControlEvents:UIControlEventValueChanged];
        [card addSubview:self.flipSwitch];

        UIView *div = [[UIView alloc] initWithFrame:CGRectMake(14, 48, cw - 28, 0.5)];
        div.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        [card addSubview:div];

        UILabel *rl = [[UILabel alloc] initWithFrame:CGRectMake(14, 56, 70, 18)];
        rl.text = @"Xoay:"; rl.font = [UIFont systemFontOfSize:13];
        rl.textColor = [UIColor whiteColor];
        [card addSubview:rl];

        self.rotateValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(cw - 58, 56, 44, 18)];
        self.rotateValueLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
        self.rotateValueLabel.textColor = [UIColor colorWithRed:0.35 green:0.85 blue:1 alpha:1];
        self.rotateValueLabel.textAlignment = NSTextAlignmentRight;
        [card addSubview:self.rotateValueLabel];

        self.rotateSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, 78, cw - 28, 28)];
        self.rotateSlider.minimumValue = -180; self.rotateSlider.maximumValue = 180;
        self.rotateSlider.tintColor = [UIColor colorWithRed:0.28 green:0.60 blue:1 alpha:1];
        [self.rotateSlider addTarget:self action:@selector(rotateChanged:)
                    forControlEvents:UIControlEventValueChanged];
        [self.rotateSlider addTarget:self action:@selector(rotateSaved)
                    forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:self.rotateSlider];
    }];

    // Reset
    y += 8;
    UIButton *reset = makeGradBtn(@"Reset tất cả", @"arrow.counterclockwise",
                                  [UIColor colorWithWhite:0.14 alpha:1],
                                  [UIColor colorWithWhite:0.07 alpha:1]);
    reset.frame = CGRectMake(mx, y, W - mx*2, 44);
    CAGradientLayer *rg = objc_getAssociatedObject(reset, "gradLayer");
    rg.frame = reset.bounds;
    [reset addTarget:self action:@selector(resetAll) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:reset];
    y += 54;

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(0, y, W, 28)];
    ver.text = @"Vcam_Mch v2.0  ·  iPhone 7 / iOS 15  ·  Rootless";
    ver.font = [UIFont systemFontOfSize:10.5];
    ver.textColor = [UIColor colorWithWhite:0.2 alpha:1];
    ver.textAlignment = NSTextAlignmentCenter;
    [scroll addSubview:ver];
    y += 40;

    scroll.contentSize = CGSizeMake(W, y);
}

// Card + section helpers
- (CGFloat)card:(UIScrollView *)sc y:(CGFloat)y mx:(CGFloat)mx W:(CGFloat)W
              h:(CGFloat)h block:(void(^)(UIView *))blk {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(mx, y, W - mx*2, h)];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    card.layer.cornerRadius = 16;
    card.layer.borderWidth  = 0.5;
    card.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    card.layer.shadowColor  = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.22;
    card.layer.shadowRadius  = 7;
    card.layer.shadowOffset  = CGSizeMake(0, 3);
    [sc addSubview:card];
    if (blk) blk(card);
    return y + h + 12;
}

- (CGFloat)sectionLbl:(UIScrollView *)sc y:(CGFloat)y mx:(CGFloat)mx text:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(mx + 4, y, 300, 16)];
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:10],
                     NSForegroundColorAttributeName:[UIColor colorWithWhite:0.32 alpha:1],
                     NSKernAttributeName:@1.8}];
    l.attributedText = as;
    [sc addSubview:l];
    return y + 24;
}

- (void)refreshUI {
    [self loadPrefs];
    BOOL on        = [self.prefs[@"isEnabled"] boolValue];
    NSInteger mode = [self.prefs[@"workMode"] integerValue];
    NSString *ip   = self.prefs[@"obsIP"]     ?: @"";
    NSString *mp   = self.prefs[@"mediaPath"] ?: @"";
    float rot      = [self.prefs[@"rotationDegrees"] floatValue];
    BOOL flip      = [self.prefs[@"horizontalFlip"] boolValue];

    self.masterSwitch.on = on;
    self.modeSeg.selectedSegmentIndex = (NSInteger)MIN(mode, 2);
    self.obsIPField.text  = ip;
    self.rotateSlider.value = rot;
    self.rotateValueLabel.text = [NSString stringWithFormat:@"%.0f°", rot];
    self.flipSwitch.on = flip;

    NSString *st;
    if (!on) {
        st = @"⬜ Virtual Camera đang TẮT";
        self.statusLabel.textColor = [UIColor colorWithWhite:0.38 alpha:1];
    } else if (mode == 0) {
        st = [NSString stringWithFormat:@"🔴 OBS → rtmp://%@:1935/live/vcam", ip.length ? ip : @"?"];
        self.statusLabel.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1];
    } else if (mp.length) {
        st = [NSString stringWithFormat:@"🟢 %@", mp.lastPathComponent];
        self.statusLabel.textColor = [UIColor colorWithRed:0.3 green:0.95 blue:0.55 alpha:1];
    } else {
        st = @"🟡 Chưa chọn file nguồn";
        self.statusLabel.textColor = [UIColor colorWithRed:1 green:0.84 blue:0.2 alpha:1];
    }
    self.statusLabel.text = st;

    self.rtmpLabel.text = [NSString stringWithFormat:
        @"OBS: rtmp://%@:1935/live/vcam", ip.length ? ip : @"IP_IPHONE"];

    self.fileNameLabel.text = mp.length
        ? [NSString stringWithFormat:@"📂 %@", mp.lastPathComponent]
        : @"Chưa chọn file";

    NSString *ds = self.prefs[@"daemonState"] ?: @"unknown";
    NSNumber *df = self.prefs[@"daemonFrames"];
    self.daemonStatusLabel.text = [NSString stringWithFormat:@"Daemon: %@%@", ds,
        df ? [NSString stringWithFormat:@" (%@ frames)", df] : @""];

    self.obsCard.alpha  = (mode == 0) ? 1.0 : 0.45;
    self.fileCard.alpha = (mode != 0) ? 1.0 : 0.45;
}

- (void)masterToggled:(UISwitch *)sw {
    self.prefs[@"isEnabled"] = @(sw.isOn);
    [self savePrefs]; [self refreshUI];
}
- (void)modeChanged:(UISegmentedControl *)seg {
    self.prefs[@"workMode"] = @(seg.selectedSegmentIndex);
    [self savePrefs]; [self refreshUI];
}
- (void)saveOBSIP {
    self.prefs[@"obsIP"] = self.obsIPField.text ?: @"";
    [self savePrefs]; [self refreshUI];
    [self.obsIPField resignFirstResponder];
}
- (void)flipToggled:(UISwitch *)sw {
    self.prefs[@"horizontalFlip"] = @(sw.isOn); [self savePrefs];
}
- (void)rotateChanged:(UISlider *)sl {
    self.rotateValueLabel.text = [NSString stringWithFormat:@"%.0f°", sl.value];
}
- (void)rotateSaved {
    self.prefs[@"rotationDegrees"] = @(self.rotateSlider.value); [self savePrefs];
}
- (void)resetAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset?"
        message:@"Xóa toàn bộ cấu hình" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        [self.prefs removeAllObjects];
        self.prefs[@"isEnabled"] = @NO;
        self.prefs[@"workMode"]  = @0;
        [self savePrefs]; [self refreshUI];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickMedia {
    NSInteger mode = [self.prefs[@"workMode"] integerValue];
    if (mode == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"OBS IP"
            message:@"Nhập IP máy tính đang chạy OBS\n(iPhone và máy tính phải cùng WiFi)"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"192.168.x.x";
            tf.text = self.prefs[@"obsIP"] ?: @"";
            tf.keyboardType = UIKeyboardTypeDecimalPad;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *ip = a.textFields.firstObject.text;
            if (ip.length) { self.prefs[@"obsIP"] = ip; [self savePrefs]; [self refreshUI]; }
        }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.selectionLimit = 1;
    cfg.filter = (mode == 2) ? [PHPickerFilter videosFilter] : [PHPickerFilter imagesFilter];
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
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
            [self savePrefs]; [self refreshUI];
        });
    }];
}

@end
