#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>

// ============================================================
// NinebotSkin v0.1.3 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
//
// v0.1.3 关键改动（针对真机反馈）:
//   1. 不再"猜容器"，而是先定位「舞台图」UIImageView（宽≈屏宽、高≈0.47屏高），
//      再把 cover/bg/veh 三个视图插成它的**兄弟视图**、紧贴其上层。
//      => overlay 与原车图在同一父视图里，滚动行为完全一致，且天然盖住原车。
//   2. 新增白色 coverView 遮罩舞台区：即使 App 把舞台图 alpha 还原，原车也露不出来。
//   3. 选图后用 ImageIO 统一转成 PNG 落盘（HEIC / 特殊 JPEG 也能用），
//      并在日志与弹窗里报告像素尺寸，彻底解决"替换后一片白"。
//   4. 看门狗：每 2.5s 轻量自检，发现舞台图被还原/overlay 被摘掉就自动补回。
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // 舞台父视图比例
static NSString * const kKeyBgRect    = @"nbskin_bg_rect";

static NSString * const kDefaultVehRect = @"0.21,0.2485,0.61,0.1981";
static NSString * const kDefaultBgRect  = @"0,0,1,0.4491";

static char NBOrigAlphaKey;

// ---------- 日志 ----------
static NSString *NBLogDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/NinebotSkin"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

static void NBLogLine(NSString *line) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *out = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"log.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sz = [[fm attributesOfItemAtPath:path error:NULL] fileSize];
    if (sz > 400 * 1024) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!h) { [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

#define NBLOG(...) do { NBLogLine([NSString stringWithFormat:__VA_ARGS__]); } while (0)

// 任意图片数据 -> PNG（同时回传像素尺寸），兼容 HEIC / CMYK / 带旋转
static NSData *NBPNGData(NSData *data, CGSize *outSize) {
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    if (outSize) *outSize = CGSizeMake(CGImageGetWidth(img), CGImageGetHeight(img));
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) { CGImageRelease(img); return nil; }
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    return ok ? out : nil;
}

// ---------- 穿透窗口 ----------
@interface NBPassThroughWindow : UIWindow
@end
@implementation NBPassThroughWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:p withEvent:event];
    if (!hit) return nil;
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface NBManager () <PHPickerViewControllerDelegate>
@property (strong, nonatomic) UIWindow *ballWindow;
@property (strong, nonatomic) UIButton *ballButton;
@property (strong, nonatomic) UIView *coverView;      // 舞台区白底遮罩
@property (strong, nonatomic) UIImageView *bgView;
@property (strong, nonatomic) UIImageView *vehView;
@property (weak,   nonatomic) UIImageView *stageView; // 原车+水印舞台图
@property (weak,   nonatomic) UIWindow *hostWindow;
@property (copy,   nonatomic) NSString *pickingSlot;
@property (copy,   nonatomic) NSString *adjustTarget;
@property (strong, nonatomic) UIPanGestureRecognizer *adjustPan;
@property (strong, nonatomic) UIPinchGestureRecognizer *adjustPinch;
@property (strong, nonatomic) NSTimer *watchdog;
@property (assign, nonatomic) NSInteger reapplyLeft;
@end

@implementation NBManager

+ (instancetype)shared {
    static NBManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

#pragma mark - 启动

- (void)boot {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:kTargetBundle]) return;
    NBLOG(@"========== NinebotSkin %@ 启动（%@ pid=%d）==========", NB_VERSION,
          [NSProcessInfo processInfo].processName, (int)getpid());
    [self setupRound:0];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onForeground)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)onForeground {
    [self applyOverlays];
    [self scheduleReapply];
}

- (void)setupRound:(NSInteger)round {
    if (round > 20) { NBLOG(@"[启动] 20 轮未就绪，放弃"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self installBall]) { [self setupRound:round + 1]; return; }
        [self applyOverlays];
        [self scheduleReapply];
        [self startWatchdog];
    });
}

- (void)scheduleReapply {
    self.reapplyLeft = 5;
    [self tickReapply];
}

- (void)tickReapply {
    if (self.reapplyLeft <= 0) return;
    self.reapplyLeft--;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self applyOverlays];
        [self tickReapply];
    });
}

- (void)startWatchdog {
    if (self.watchdog) return;
    __weak NBManager *weakSelf = self;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:2.5 repeats:YES block:^(NSTimer *t) {
        [weakSelf watchdogTick];
    }];
    NBLOG(@"[看门狗] 启动");
}

- (void)watchdogTick {
    if (![self hasAnyReplacement]) return;
    UIImageView *stage = [self findStageImageView];
    if (!stage) return;
    BOOL lost = (self.bgView && !self.bgView.superview);
    if (self.vehView && !self.vehView.superview) lost = YES;
    BOOL stageBack = (stage.alpha > 0.01);
    BOOL wrongOrder = (self.bgView && self.bgView.superview == stage.superview &&
                       [stage.superview.subviews indexOfObject:self.bgView] <
                       [stage.superview.subviews indexOfObject:stage]);
    if (lost || stageBack || wrongOrder) {
        NBLOG(@"[看门狗] 补应用 lost=%d stageBack=%d order=%d", (int)lost, (int)stageBack, (int)wrongOrder);
        [self applyOverlays];
    }
}

#pragma mark - 悬浮球

- (BOOL)installBall {
    if (self.ballWindow && self.ballWindow.windowScene) return YES;
    UIWindowScene *scene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
    }
    if (!scene) return NO;

    NBPassThroughWindow *w = [[NBPassThroughWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 100.0;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeSystem];
    ball.layer.cornerRadius = 24.0;
    ball.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    ball.titleLabel.font = [UIFont systemFontOfSize:26.0];
    [ball setTitle:@"🛴" forState:UIControlStateNormal];
    CGRect sb = [UIScreen mainScreen].bounds;
    ball.frame = CGRectMake(sb.size.width - 66.0, sb.size.height - 230.0, 48.0, 48.0);
    [ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballPanned:)];
    [ball addGestureRecognizer:pan];
    [w.rootViewController.view addSubview:ball];

    self.ballButton = ball;
    self.ballWindow = w;
    w.hidden = NO;
    NBLOG(@"[悬浮球] 已创建 level=%.0f", w.windowLevel);
    return YES;
}

- (void)ballPanned:(UIPanGestureRecognizer *)pan {
    UIButton *ball = self.ballButton;
    if (!ball) return;
    CGPoint t = [pan translationInView:ball.superview];
    if (pan.state == UIGestureRecognizerStateBegan) return;
    CGRect f = ball.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    UIView *sv = ball.superview;
    if (sv) {
        f.origin.x = MAX(4.0, MIN(sv.bounds.size.width  - f.size.width  - 4.0, f.origin.x));
        f.origin.y = MAX(40.0, MIN(sv.bounds.size.height - f.size.height - 4.0, f.origin.y));
    }
    ball.frame = f;
    [pan setTranslation:CGPointZero inView:ball.superview];
}

- (void)ballTapped {
    if (self.adjustTarget) { [self finishAdjust]; return; }
    UIViewController *top = [self topVC];
    if (!top) { NBLOG(@"[菜单] 找不到可用顶层 VC"); return; }
    self.ballWindow.hidden = YES;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"九号换装"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【车辆图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"veh"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【背景图片】（ninebot 区域）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"bg"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"微调车辆图（拖动/双指缩放）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self beginAdjust:@"veh"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"微调背景区域" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self beginAdjust:@"bg"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"车辆图对准原车（重置位置）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self resetVehicleRect]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复车辆原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreVehicle]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复背景原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreBackground]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"调试：导出视图树" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self dumpViewTree]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *action){ [self unhideBall]; }]];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.ballButton ?: top.view;
        ac.popoverPresentationController.sourceRect = (self.ballButton ?: top.view).bounds;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)unhideBall { self.ballWindow.hidden = NO; }

- (void)presentTracked:(UIViewController *)vc {
    UIViewController *top = [self topVC];
    if (!top) { [self unhideBall]; return; }
    [top presentViewController:vc animated:YES completion:nil];
}

- (UIViewController *)topVC {
    UIWindow *win = [self appMainWindow];
    UIViewController *vc = win.rootViewController;
    if (!vc) return nil;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

- (UIWindow *)appMainWindow {
    UIWindow *best = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w == self.ballWindow) continue;
            if (w.hidden || !w.rootViewController) continue;
            if (w.windowLevel != UIWindowLevelNormal) continue;
            best = w; break;
        }
        if (best) break;
    }
    return best;
}

#pragma mark - 舞台图定位

- (UIImageView *)findStageImageView {
    UIWindow *win = [self appMainWindow];
    if (!win || !win.rootViewController.view) return nil;
    CGSize ws = win.bounds.size;
    UIImageView *best = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win.rootViewController.view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == self.bgView || v == self.vehView || v == self.coverView) continue;
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            CGSize b = iv.bounds.size;
            if (iv.image && !iv.hidden && b.width >= ws.width * 0.85 &&
                b.height >= ws.height * 0.20 && b.height <= ws.height * 0.65) {
                if (!best || b.height > best.bounds.size.height) best = iv;
            }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return best;
}

- (BOOL)hasAnyReplacement {
    return [self storedPathForSlot:@"bg"] != nil || [self storedPathForSlot:@"veh"] != nil;
}

- (void)setStageHidden:(BOOL)hidden stage:(UIImageView *)stage {
    if (!stage) return;
    if (hidden) {
        if (!objc_getAssociatedObject(stage, &NBOrigAlphaKey))
            objc_setAssociatedObject(stage, &NBOrigAlphaKey, @(stage.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        stage.alpha = 0.0;
        // 同尺寸的兄弟图一起隐藏（多套皮肤缓存）
        UIView *host = stage.superview;
        for (UIView *s in host.subviews) {
            if (s == stage || ![s isKindOfClass:[UIImageView class]]) continue;
            UIImageView *iv = (UIImageView *)s;
            if (!iv.image) continue;
            if (fabs(iv.frame.size.width - stage.frame.size.width) > 1.0) continue;
            if (fabs(iv.frame.size.height - stage.frame.size.height) > 1.0) continue;
            if (!objc_getAssociatedObject(iv, &NBOrigAlphaKey))
                objc_setAssociatedObject(iv, &NBOrigAlphaKey, @(iv.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            iv.alpha = 0.0;
        }
    } else {
        NSArray<UIView *> *subs = stage.superview.subviews;
        for (UIView *s in subs) {
            id oa = objc_getAssociatedObject(s, &NBOrigAlphaKey);
            if (oa) {
                s.alpha = [oa floatValue];
                objc_setAssociatedObject(s, &NBOrigAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

#pragma mark - 选图

- (void)pickImageFor:(NSString *)slot {
    self.pickingSlot = slot;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    NBLOG(@"[选图] 打开 picker slot=%@", slot);
    [self presentTracked:picker];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSString *slot = self.pickingSlot ?: @"bg";
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *res = [results firstObject];
    if (!res) { [self unhideBall]; return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSData *data = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [res.itemProvider loadFileRepresentationForTypeIdentifier:@"public.image"
                                               completionHandler:^(NSURL *url, NSError *error) {
            if (url) {
                [url startAccessingSecurityScopedResource];
                data = [NSData dataWithContentsOfURL:url];
                [url stopAccessingSecurityScopedResource];
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        if (!data) {
            [res.itemProvider loadDataRepresentationForTypeIdentifier:@"public.image"
                                                    completionHandler:^(NSData *d2, NSError *e2) {
                data = d2;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        }

        CGSize px = CGSizeZero;
        NSData *png = NBPNGData(data, &px);
        BOOL ok = NO;
        NSString *savedPath = nil;
        if (png.length) {
            NSString *path = [NBLogDir() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.png", slot]];
            ok = [png writeToFile:path atomically:YES];
            savedPath = path;
            [[NSFileManager defaultManager] removeItemAtPath:
             [NBLogDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.img", slot]]
                                                      error:NULL];
        }
        NBLOG(@"[选图] slot=%@ 原始 %luB -> png %luB %.0fx%.0f ok=%d",
              slot, (unsigned long)data.length, (unsigned long)png.length, px.width, px.height, (int)ok);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
                [[NSUserDefaults standardUserDefaults] setObject:savedPath forKey:key];
                [self applyOverlays];
                [self scheduleReapply];
                NSString *label = [slot isEqualToString:@"veh"] ? @"车辆图片" : @"背景图片";
                [self alertDone:[NSString stringWithFormat:@"已替换%@\n%@×%@ px\n原车/水印已隐藏",
                                 label, @((NSInteger)px.width), @((NSInteger)px.height)]];
            } else {
                [self alertDone:@"图片解析失败（可能是特殊格式），请换一张"];
            }
        });
    });
}

- (void)alertDone:(NSString *)msg {
    UIViewController *top = [self topVC];
    if (!top) { [self unhideBall]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"九号换装"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self unhideBall]; }]];
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 位置

- (CGRect)frameForRectKey:(NSString *)key default:(NSString *)def inView:(UIView *)ref {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!raw.length) raw = def;
    if (!raw.length) return CGRectZero;
    NSArray *p = [raw componentsSeparatedByString:@","];
    CGFloat fx = p.count > 0 ? [p[0] floatValue] : 0.0;
    CGFloat fy = p.count > 1 ? [p[1] floatValue] : 0.0;
    CGFloat fw = p.count > 2 ? [p[2] floatValue] : 1.0;
    CGFloat fh = p.count > 3 ? [p[3] floatValue] : 1.0;
    CGSize s = ref.bounds.size;
    return CGRectMake(fx * s.width, fy * s.height, fw * s.width, fh * s.height);
}

- (NSString *)storedPathForSlot:(NSString *)slot {
    NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!p.length || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

#pragma mark - 应用 overlay

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win) return;
    self.hostWindow = win;

    UIImageView *stage = [self findStageImageView];
    if (!stage || !stage.superview) { NBLOG(@"[overlay] 未找到舞台图"); return; }
    self.stageView = stage;
    UIView *host = stage.superview;
    CGRect stageRect = stage.frame;

    NSString *bgPath = [self storedPathForSlot:@"bg"];
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    UIImage *vehImg = vehPath ? [UIImage imageWithContentsOfFile:vehPath] : nil;
    if (bgPath && !bgImg) NBLOG(@"[overlay] ⚠️ 背景图解码失败：%@", bgPath);
    if (vehPath && !vehImg) NBLOG(@"[overlay] ⚠️ 车辆图解码失败：%@", vehPath);

    BOOL active = (bgImg != nil || vehImg != nil);

    if (!active) {
        [self setStageHidden:NO stage:stage];
        [self.coverView removeFromSuperview];
        [self.bgView removeFromSuperview];
        [self.vehView removeFromSuperview];
        return;
    }

    [self setStageHidden:YES stage:stage];

    // 三个视图先从父视图摘下，保证插入顺序可控
    if (self.coverView.superview) [self.coverView removeFromSuperview];
    if (self.bgView.superview) [self.bgView removeFromSuperview];
    if (self.vehView.superview) [self.vehView removeFromSuperview];

    // 白底遮罩：原车即使被 App 还原 alpha 也露不出来
    if (!self.coverView) {
        self.coverView = [UIView new];
        self.coverView.userInteractionEnabled = NO;
        self.coverView.backgroundColor = [UIColor whiteColor];
    }
    self.coverView.frame = stageRect;

    if (bgImg) {
        if (!self.bgView) {
            self.bgView = [UIImageView new];
            self.bgView.userInteractionEnabled = NO;
            self.bgView.contentMode = UIViewContentModeScaleAspectFill;
            self.bgView.clipsToBounds = YES;
            self.bgView.backgroundColor = [UIColor whiteColor];
        }
        self.bgView.image = bgImg;
        NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgRect];
        if (![self.adjustTarget isEqualToString:@"bg"]) {
            self.bgView.frame = custom.length ? [self frameForRectKey:kKeyBgRect default:kDefaultBgRect inView:host]
                                              : stageRect;
        }
    }

    if (vehImg) {
        if (!self.vehView) {
            self.vehView = [UIImageView new];
            self.vehView.userInteractionEnabled = NO;
            self.vehView.contentMode = UIViewContentModeScaleAspectFit;
        }
        self.vehView.image = vehImg;
        if (![self.adjustTarget isEqualToString:@"veh"]) {
            self.vehView.frame = [self frameForRectKey:kKeyVehRect default:kDefaultVehRect inView:host];
        }
    }

    // 统一插入：紧贴舞台图之上（cover -> bg -> veh），与原车同一父视图 => 滚动同步
    NSUInteger idx = [host.subviews indexOfObject:stage];
    if (idx == NSNotFound) idx = host.subviews.count ? host.subviews.count - 1 : 0;
    NSUInteger ins = idx + 1;
    [host insertSubview:self.coverView atIndex:MIN(ins, host.subviews.count)];
    ins++;
    if (bgImg) {
        [host insertSubview:self.bgView atIndex:MIN(ins, host.subviews.count)];
        ins++;
    }
    if (vehImg) {
        [host insertSubview:self.vehView atIndex:MIN(ins, host.subviews.count)];
    }

    NBLOG(@"[overlay] host=%@ stage=%@ bg=%d veh=%d cover=%@",
          NSStringFromClass([host class]), NSStringFromCGRect(stageRect),
          bgImg != nil, vehImg != nil, NSStringFromCGRect(self.coverView.frame));
}

#pragma mark - 现场微调

- (void)beginAdjust:(NSString *)target {
    BOOL isBG = [target isEqualToString:@"bg"];
    UIView *v = isBG ? self.bgView : self.vehView;
    if (!v) { [self alertDone:isBG ? @"还没有替换背景图片" : @"还没有替换车辆图片"]; return; }
    self.adjustTarget = target;
    v.userInteractionEnabled = YES;
    v.layer.borderWidth = 1.5;
    v.layer.borderColor = [UIColor systemBlueColor].CGColor;
    if (!self.adjustPan) {
        self.adjustPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPanned:)];
        self.adjustPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPinched:)];
    }
    if (self.adjustPan.view) [self.adjustPan.view removeGestureRecognizer:self.adjustPan];
    if (self.adjustPinch.view) [self.adjustPinch.view removeGestureRecognizer:self.adjustPinch];
    [v addGestureRecognizer:self.adjustPan];
    [v addGestureRecognizer:self.adjustPinch];
    [v.superview bringSubviewToFront:v];
    [self.ballButton setTitle:@"✓" forState:UIControlStateNormal];
    [self unhideBall];
    NBLOG(@"[微调] 进入 %@ frame=%@", target, NSStringFromCGRect(v.frame));
}

- (void)adjustPanned:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    CGRect f = v.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    UIView *sv = v.superview;
    if (sv) {
        f.origin.x = MAX(-f.size.width  * 0.5, MIN(sv.bounds.size.width  - f.size.width  * 0.5, f.origin.x));
        f.origin.y = MAX(-f.size.height * 0.5, MIN(sv.bounds.size.height - f.size.height * 0.5, f.origin.y));
    }
    v.frame = f;
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)adjustPinched:(UIPinchGestureRecognizer *)g {
    UIView *v = g.view;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        CGRect f = v.frame;
        CGFloat w = f.size.width * g.scale, h = f.size.height * g.scale;
        CGPoint c = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        if (w < 40.0) { h *= (40.0 / w); w = 40.0; }
        v.frame = CGRectMake(c.x - w / 2.0, c.y - h / 2.0, w, h);
        g.scale = 1.0;
    }
}

- (void)finishAdjust {
    BOOL isBG = [self.adjustTarget isEqualToString:@"bg"];
    UIView *v = isBG ? self.bgView : self.vehView;
    UIView *host = v.superview;
    if (v && host) {
        CGFloat W = host.bounds.size.width, H = host.bounds.size.height;
        if (W > 1 && H > 1) {
            CGRect f = v.frame;
            NSString *rect = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                              f.origin.x / W, f.origin.y / H, f.size.width / W, f.size.height / H];
            NSString *key = isBG ? kKeyBgRect : kKeyVehRect;
            [[NSUserDefaults standardUserDefaults] setObject:rect forKey:key];
            NBLOG(@"[微调] 保存 %@ = %@", isBG ? @"bg" : @"veh", rect);
        }
    }
    v.userInteractionEnabled = NO;
    v.layer.borderWidth = 0.0;
    self.adjustTarget = nil;
    [self.ballButton setTitle:@"🛴" forState:UIControlStateNormal];
    [self applyOverlays];
    [self alertDone:isBG ? @"背景区域已保存" : @"车辆图位置已保存"];
}

- (void)resetVehicleRect {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
    [self applyOverlays];
    [self alertDone:@"车辆图已对准原车位置"];
    NBLOG(@"[重置] 车辆框恢复默认");
}

#pragma mark - 恢复

- (void)restoreVehicle {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehPath];
    [self applyOverlays];
    [self alertDone:@"已恢复车辆原图"];
    NBLOG(@"[恢复] 车辆图");
}

- (void)restoreBackground {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgPath];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgRect];
    [self applyOverlays];
    [self alertDone:@"已恢复背景原图"];
    NBLOG(@"[恢复] 背景");
}

#pragma mark - 调试

- (void)dumpViewTree {
    NSMutableString *out = [NSMutableString stringWithCapacity:8192];
    [out appendFormat:@"==== NinebotSkin %@ viewtree %@ ====\n", NB_VERSION, [NSDate date]];
    UIWindow *win = [self appMainWindow];
    if (win) {
        [out appendFormat:@"[window] %@ bounds=%@\n", NSStringFromClass([win class]),
         NSStringFromCGRect(win.bounds)];
        UIImageView *stage = [self findStageImageView];
        [out appendFormat:@"[stage] %@ frame=%@ alpha=%.2f\n", stage ? NSStringFromClass([stage class]) : @"nil",
         stage ? NSStringFromCGRect(stage.frame) : @"-", stage ? stage.alpha : -1.0];
        [self dump:win.rootViewController.view to:out depth:0];
    }
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self alertDone:[NSString stringWithFormat:@"已导出:\n%@", path]];
    NBLOG(@"[调试] 导出 %lu 字节", (unsigned long)out.length);
}

- (void)dump:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
    if (!view || depth > 18) return;
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@ img=%@ %@\n",
     [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha, (int)view.hidden,
     view.backgroundColor ? @"Y" : @"-",
     view.layer.contents ? @"Y" : @"-",
     (view == self.coverView ? @"<COVER>" : (view == self.bgView ? @"<BG>" : (view == self.vehView ? @"<VEH>" : @"")))];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end
