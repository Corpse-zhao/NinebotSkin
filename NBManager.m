#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <unistd.h>

// ============================================================
// NinebotSkin v0.1.1 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
// 设计: 零私有类 hook；悬浮球(独立 UIWindow) + 菜单 + overlay 替换
//
// v0.1.1 修复:
//   1. 车辆图改为「现场拖拽 + 双指缩放」调整，保存为屏幕比例
//   2. 背景不生效: SwiftUI 页面背景是不透明绘制层(非 backgroundColor)
//      -> 增加「全屏不透明图层击杀」+ 应用后多次重试
//   3. 视图树 dump 深度 9 -> 18，并打印 layer.contents
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // "fx,fy,fw,fh" 屏幕比例

// 车辆图默认框（按视频实测比例，可现场调整）
static NSString * const kDefaultVehRect = @"0.08,0.22,0.84,0.34";

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

// ---------- 穿透窗口：空白区域把触摸还给 App，只有小球可点 ----------
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

// ---------- 原始状态缓存（用于恢复） ----------
static char NBOrigColorKey;
static char NBOrigLayerKey;
static char NBOrigAlphaKey;
static char NBOrigEffectKey;

@interface NBManager () <PHPickerViewControllerDelegate>
@property (strong, nonatomic) UIWindow *ballWindow;
@property (strong, nonatomic) UIButton *ballButton;
@property (strong, nonatomic) UIImageView *bgView;
@property (strong, nonatomic) UIImageView *vehView;
@property (strong, nonatomic) UIWindow *hostWindow;
@property (copy,   nonatomic) NSString *pickingSlot;
@property (assign, nonatomic) BOOL editingVehicle;
@property (strong, nonatomic) UIPanGestureRecognizer *vehPan;
@property (strong, nonatomic) UIPinchGestureRecognizer *vehPinch;
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
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:kTargetBundle]) return;
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
    });
}

// 应用后连续重试若干次：App 建 UI 是异步的，早应用会被后建的不透明层盖住
- (void)scheduleReapply {
    self.reapplyLeft = 5;
    [self tickReapply];
}

- (void)tickReapply {
    if (self.reapplyLeft <= 0) return;
    self.reapplyLeft--;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self applyOverlays];
        [self tickReapply];
    });
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
    w.hidden = NO; // 绝不 makeKeyAndVisible
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
    if (self.editingVehicle) { [self finishAdjustVehicle]; return; }
    UIViewController *top = [self topVC];
    if (!top) { NBLOG(@"[菜单] 找不到可用的顶层 VC"); return; }
    self.ballWindow.hidden = YES;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"九号换装"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【背景图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"bg"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【车辆图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"veh"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"调整车辆图位置（拖动/双指缩放）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self beginAdjustVehicle]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复车辆原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreVehicle]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复背景原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreBackground]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"背景诊断：置顶 3 秒" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self bgTestTop]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新应用（切页后用）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self applyOverlays]; [self scheduleReapply]; [self alertDone:@"已重新应用"]; }]];
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

- (void)unhideBall {
    self.ballWindow.hidden = NO;
}

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

#pragma mark - 选图（PHPicker）

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

        BOOL ok = NO; NSString *savedPath = nil;
        if (data.length > 0) {
            NSString *path = [NBLogDir() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.img", slot]];
            ok = [data writeToFile:path atomically:YES]; // NSData 的写法
            savedPath = path;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [[NSUserDefaults standardUserDefaults] setObject:savedPath
                                                          forKey:[slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath];
                [self applyOverlays];
                [self scheduleReapply];
                if ([slot isEqualToString:@"veh"]) {
                    [self alertDone:@"已替换车辆图片\n可再点悬浮球选「调整车辆图位置」微调"];
                } else {
                    [self alertDone:@"已替换背景图片"];
                }
                NBLOG(@"[选图] 成功 slot=%@ size=%lu", slot, (unsigned long)data.length);
            } else {
                [self alertDone:@"导入失败，请换一张图片试试"];
                NBLOG(@"[选图] 失败 slot=%@", slot);
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

#pragma mark - 车辆图现场调整

- (void)beginAdjustVehicle {
    if (!self.vehView) { [self alertDone:@"还没有替换车辆图片"]; return; }
    self.editingVehicle = YES;
    self.vehView.userInteractionEnabled = YES;
    self.vehView.layer.borderWidth = 1.5;
    self.vehView.layer.borderColor = [UIColor systemBlueColor].CGColor;
    if (!self.vehPan) {
        self.vehPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(vehPanned:)];
        [self.vehView addGestureRecognizer:self.vehPan];
    }
    if (!self.vehPinch) {
        self.vehPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(vehPinched:)];
        [self.vehView addGestureRecognizer:self.vehPinch];
    }
    [self.ballButton setTitle:@"✓" forState:UIControlStateNormal];
    [self unhideBall];
    NBLOG(@"[调整] 进入编辑模式 frame=%@", NSStringFromCGRect(self.vehView.frame));
}

- (void)vehPanned:(UIPanGestureRecognizer *)g {
    UIView *v = self.vehView;
    if (!v) return;
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

- (void)vehPinched:(UIPinchGestureRecognizer *)g {
    UIView *v = self.vehView;
    if (!v) return;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        CGRect f = v.frame;
        CGFloat w = f.size.width * g.scale;
        CGFloat h = f.size.height * g.scale;
        CGPoint c = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        CGFloat minW = 40.0;
        if (w < minW) { h *= (minW / w); w = minW; }
        v.frame = CGRectMake(c.x - w / 2.0, c.y - h / 2.0, w, h);
        g.scale = 1.0;
    }
}

- (void)finishAdjustVehicle {
    self.editingVehicle = NO;
    UIView *v = self.vehView;
    UIWindow *win = v.superview ?: [self appMainWindow];
    if (v && win) {
        CGFloat W = win.bounds.size.width, H = win.bounds.size.height;
        if (W > 1 && H > 1) {
            CGRect f = v.frame;
            NSString *rect = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                              f.origin.x / W, f.origin.y / H, f.size.width / W, f.size.height / H];
            [[NSUserDefaults standardUserDefaults] setObject:rect forKey:kKeyVehRect];
            NBLOG(@"[调整] 已保存 rect=%@ (frame=%@ win=%@)", rect,
                  NSStringFromCGRect(f), NSStringFromCGSize(win.bounds.size));
        }
    }
    v.userInteractionEnabled = NO;
    v.layer.borderWidth = 0.0;
    [self.ballButton setTitle:@"🛴" forState:UIControlStateNormal];
    [self alertDone:@"车辆图位置已保存"];
}

#pragma mark - Overlay 应用

- (NSString *)storedPathForSlot:(NSString *)slot {
    NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!p.length) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

- (CGRect)vehicleFrameIn:(UIWindow *)win {
    NSString *def = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyVehRect];
    if (!def.length) def = kDefaultVehRect;
    NSArray *parts = [def componentsSeparatedByString:@","];
    CGFloat fx = [parts count] > 0 ? [parts[0] floatValue] : 0.08;
    CGFloat fy = [parts count] > 1 ? [parts[1] floatValue] : 0.22;
    CGFloat fw = [parts count] > 2 ? [parts[2] floatValue] : 0.84;
    CGFloat fh = [parts count] > 3 ? [parts[3] floatValue] : 0.34;
    CGSize sz = win.bounds.size;
    return CGRectMake(fx * sz.width, fy * sz.height, fw * sz.width, fh * sz.height);
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win || !win.rootViewController.view) { NBLOG(@"[overlay] 无主窗口"); return; }
    self.hostWindow = win;
    UIView *root = win.rootViewController.view;

    // ---- 背景 ----
    NSString *bgPath = [self storedPathForSlot:@"bg"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    if (bgImg) {
        if (!self.bgView) {
            self.bgView = [UIImageView new];
            self.bgView.userInteractionEnabled = NO;
            self.bgView.contentMode = UIViewContentModeScaleAspectFill;
            self.bgView.clipsToBounds = YES;
        }
        self.bgView.image = bgImg;
        self.bgView.frame = win.bounds;
        self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (self.bgView.superview != win) {
            [self.bgView removeFromSuperview];
            [win insertSubview:self.bgView atIndex:0];
            NBLOG(@"[overlay] 背景视图已插入 window index0");
        }
        [self killOpaqueCovers:root depth:0];
        [self killOpaqueCovers:win depth:0];
    } else if (self.bgView) {
        [self.bgView removeFromSuperview];
    }

    // ---- 车辆 ----
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *vehImg = vehPath ? [UIImage imageWithContentsOfFile:vehPath] : nil;
    if (vehImg) {
        if (!self.vehView) {
            self.vehView = [UIImageView new];
            self.vehView.userInteractionEnabled = NO;
            self.vehView.contentMode = UIViewContentModeScaleAspectFit;
        }
        self.vehView.image = vehImg;
        if (!self.editingVehicle) self.vehView.frame = [self vehicleFrameIn:win];
        if (self.vehView.superview != win) {
            [self.vehView removeFromSuperview];
            [win addSubview:self.vehView]; // 顶层，保证可见
        } else {
            [win bringSubviewToFront:self.vehView];
        }
    } else if (self.vehView) {
        [self.vehView removeFromSuperview];
    }
}

// 击杀「不透明全屏层」：SwiftUI/UIKit 的页面底色常是一张铺满屏的图片或 layer.contents，
// 光清 backgroundColor 无效，必须让这些层透明，底下的背景图才看得见。
- (void)killOpaqueCovers:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 12) return;
    if (view == self.bgView || view == self.vehView) return;
    if ([view isKindOfClass:[UIWindow class]] && view != self.hostWindow) return;

    CGSize winSize = self.hostWindow ? self.hostWindow.bounds.size : CGSizeZero;
    CGRect inWin = self.hostWindow ? [view convertRect:view.bounds toView:self.hostWindow] : CGRectZero;
    BOOL fullscreen = (winSize.width > 1 &&
                       inWin.size.width  >= winSize.width  * 0.95 &&
                       inWin.size.height >= winSize.height * 0.90);

    if (fullscreen) {
        BOOL hasPaint = NO;
        if ([view isKindOfClass:[UIImageView class]] && ((UIImageView *)view).image) hasPaint = YES;
        if (view.layer.contents) hasPaint = YES;
        if (hasPaint && view.alpha > 0.01) {
            if (!objc_getAssociatedObject(view, &NBOrigAlphaKey))
                objc_setAssociatedObject(view, &NBOrigAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.alpha = 0.0;
            static NSInteger killed = 0;
            if (killed < 40) {
                killed++;
                NBLOG(@"[击杀] %@ frame=%@", NSStringFromClass([view class]), NSStringFromCGRect(inWin));
            }
        }
    }

    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)view;
        if (fullscreen && ev.effect) {
            if (!objc_getAssociatedObject(ev, &NBOrigEffectKey))
                objc_setAssociatedObject(ev, &NBOrigEffectKey, ev.effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ev.effect = nil;
        }
        return;
    }

    if (view.backgroundColor && ![view.backgroundColor isEqual:[UIColor clearColor]]) {
        if (!objc_getAssociatedObject(view, &NBOrigColorKey))
            objc_setAssociatedObject(view, &NBOrigColorKey, view.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.backgroundColor = [UIColor clearColor];
    }
    if (view.layer.backgroundColor) {
        if (!objc_getAssociatedObject(view, &NBOrigLayerKey))
            objc_setAssociatedObject(view, &NBOrigLayerKey, (__bridge id)(view.layer.backgroundColor),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.layer.backgroundColor = NULL;
    }

    for (UIView *sub in [view.subviews copy]) [self killOpaqueCovers:sub depth:depth + 1];
}

// 还原所有被改动过的视图
- (void)restoreAllVisuals {
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    if (self.hostWindow.rootViewController.view) [stack addObject:self.hostWindow.rootViewController.view];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        id oc = objc_getAssociatedObject(v, &NBOrigColorKey);
        if (oc) { v.backgroundColor = oc; objc_setAssociatedObject(v, &NBOrigColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        id ol = objc_getAssociatedObject(v, &NBOrigLayerKey);
        if (ol) { v.layer.backgroundColor = (__bridge CGColorRef)ol; objc_setAssociatedObject(v, &NBOrigLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        id oa = objc_getAssociatedObject(v, &NBOrigAlphaKey);
        if (oa) { v.alpha = [oa floatValue]; objc_setAssociatedObject(v, &NBOrigAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        id oe = objc_getAssociatedObject(v, &NBOrigEffectKey);
        if (oe && [v isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)v).effect = oe;
            objc_setAssociatedObject(v, &NBOrigEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (UIView *sub in [v.subviews copy]) [stack addObject:sub];
    }
    NBLOG(@"[恢复] 视觉状态已还原");
}

- (void)bgTestTop {
    if (!self.bgView) { [self alertDone:@"还没有替换背景图片"]; return; }
    UIWindow *win = self.bgView.superview ?: [self appMainWindow];
    if (!win) return;
    [win addSubview:self.bgView];
    self.bgView.frame = win.bounds;
    [self alertDone:@"背景已置顶 3 秒\n看到图片=图片正常，仅被 App 图层盖住；看不到=导入有问题"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.bgView removeFromSuperview];
        [win insertSubview:self.bgView atIndex:0];
        [self scheduleReapply];
    });
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
    [self restoreAllVisuals];
    [self applyOverlays];
    [self alertDone:@"已恢复背景原图"];
    NBLOG(@"[恢复] 背景");
}

#pragma mark - 调试：视图树导出

- (void)dumpViewTree {
    NSMutableString *out = [NSMutableString stringWithCapacity:8192];
    [out appendFormat:@"==== NinebotSkin %@ viewtree %@ ====\n", NB_VERSION, [NSDate date]];
    UIWindow *win = [self appMainWindow];
    if (win) {
        [out appendFormat:@"[window] %@ bounds=%@\n", NSStringFromClass([win class]),
         NSStringFromCGRect(win.bounds)];
        [self dump:win.rootViewController.view to:out depth:0];
    }
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self alertDone:[NSString stringWithFormat:@"已导出:\n%@", path]];
    NBLOG(@"[调试] 视图树导出 %lu 字节", (unsigned long)out.length);
}

- (void)dump:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
    if (!view || depth > 18) return;
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@ img=%@\n",
     [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha, (int)view.hidden,
     view.backgroundColor ? @"Y" : @"-",
     view.layer.contents ? @"Y" : @"-"];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end
