#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <unistd.h>

// ============================================================
// NinebotSkin v0.1.0 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
// 设计: 零私有类 hook；悬浮球(独立 UIWindow) + 菜单 + overlay 替换
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // "fx,fy,fw,fh" 屏幕比例

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
    if (hit == self || hit == self.rootViewController.view) return nil; // 背景穿透
    return hit;
}
@end

// ---------- 颜色缓存（用于恢复原图） ----------
static char NBOrigColorKey;
static char NBOrigLayerKey;

@interface NBManager () <PHPickerViewControllerDelegate>
@property (strong, nonatomic) UIWindow *ballWindow;
@property (strong, nonatomic) UIButton *ballButton;
@property (strong, nonatomic) UIImageView *bgView;
@property (strong, nonatomic) UIImageView *vehView;
@property (copy,   nonatomic) NSString *pickingSlot; // @"bg" / @"veh"
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
}

- (void)setupRound:(NSInteger)round {
    if (round > 20) { NBLOG(@"[启动] 20 轮未就绪，放弃"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self installBall]) { [self setupRound:round + 1]; return; }
        [self applyOverlays];
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
    NBLOG(@"[悬浮球] 已创建 level=%.0f scene=%d", w.windowLevel, (int)(scene != nil));
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
    UIViewController *top = [self topVC];
    if (!top) { NBLOG(@"[菜单] 找不到可用的顶层 VC"); return; }
    self.ballWindow.hidden = YES; // 弹菜单期间收起小球，避免盖住弹窗

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"九号换装"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【背景图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"bg"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【车辆图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self pickImageFor:@"veh"]; }]];
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

- (void)unhideBall {
    self.ballWindow.hidden = NO;
}

// 弹出选择器/菜单的统一入口
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
            ok = [data writeToFile:path atomically:YES];
            savedPath = path;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [[NSUserDefaults standardUserDefaults] setObject:savedPath
                                                          forKey:[slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath];
                [self applyOverlays];
                [self alertDone:[NSString stringWithFormat:@"已替换%@",
                                 [slot isEqualToString:@"veh"] ? @"车辆图片" : @"背景图片"]];
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

#pragma mark - Overlay 应用

- (NSString *)storedPathForSlot:(NSString *)slot {
    NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!p.length) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win || !win.rootViewController.view) { NBLOG(@"[overlay] 无主窗口"); return; }
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
        }
        [self sweep:root mode:YES depth:0];
        NBLOG(@"[overlay] 背景已应用 %@", bgPath.lastPathComponent);
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
        self.vehView.frame = [self vehicleFrameIn:win];
        if (self.vehView.superview != win) {
            [self.vehView removeFromSuperview];
            [win addSubview:self.vehView]; // 顶层，保证可见
        }
        NBLOG(@"[overlay] 车辆图已应用 frame=%@",
              NSStringFromCGRect(self.vehView.frame));
    } else if (self.vehView) {
        [self.vehView removeFromSuperview];
    }
}

- (CGRect)vehicleFrameIn:(UIWindow *)win {
    NSString *def = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyVehRect];
    if (!def.length) def = @"0.05,0.17,0.90,0.42";
    NSArray *parts = [def componentsSeparatedByString:@","];
    CGFloat fx = [parts count] > 0 ? [parts[0] floatValue] : 0.05;
    CGFloat fy = [parts count] > 1 ? [parts[1] floatValue] : 0.17;
    CGFloat fw = [parts count] > 2 ? [parts[2] floatValue] : 0.90;
    CGFloat fh = [parts count] > 3 ? [parts[3] floatValue] : 0.42;
    CGSize sz = win.bounds.size;
    return CGRectMake(fx * sz.width, fy * sz.height, fw * sz.width, fh * sz.height);
}

// mode=YES 应用(缓存+清色) / mode=NO 恢复
- (void)sweep:(UIView *)view mode:(BOOL)apply depth:(NSInteger)depth {
    if (!view || depth > 5) return;
    if (view == self.bgView || view == self.vehView) return;

    // 保留交互控件与文字
    if ([view isKindOfClass:[UIControl class]] ||
        [view isKindOfClass:[UILabel class]] ||
        [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UITextView class]] ||
        [view isKindOfClass:[UITableViewCell class]] ||
        [view isKindOfClass:[UICollectionViewCell class]]) return;

    // 毛玻璃：大面积的直接摘 effect
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)view;
        CGSize s = ev.bounds.size, ps = ev.superview ? ev.superview.bounds.size : CGSizeZero;
        BOOL big = (ps.width > 1 && s.width >= ps.width * 0.9 && s.height >= ps.height * 0.9);
        if (big && apply && ev.effect) {
            if (!objc_getAssociatedObject(ev, &NBOrigColorKey))
                objc_setAssociatedObject(ev, &NBOrigColorKey, ev.effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ev.effect = nil;
        } else if (!apply) {
            id orig = objc_getAssociatedObject(ev, &NBOrigColorKey);
            if (orig) ev.effect = orig;
        }
        return;
    }

    if (apply) {
        if (view.backgroundColor && ![view.backgroundColor isEqual:[UIColor clearColor]]) {
            if (!objc_getAssociatedObject(view, &NBOrigColorKey))
                objc_setAssociatedObject(view, &NBOrigColorKey, view.backgroundColor,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.backgroundColor = [UIColor clearColor];
        }
        if (view.layer.backgroundColor) {
            if (!objc_getAssociatedObject(view, &NBOrigLayerKey))
                objc_setAssociatedObject(view, &NBOrigLayerKey,
                                         (__bridge id)(view.layer.backgroundColor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.layer.backgroundColor = NULL;
        }
    } else {
        id oc = objc_getAssociatedObject(view, &NBOrigColorKey);
        if (oc) view.backgroundColor = oc;
        id ol = objc_getAssociatedObject(view, &NBOrigLayerKey);
        if (ol) view.layer.backgroundColor = (__bridge CGColorRef)ol;
    }

    for (UIView *sub in [view.subviews copy]) [self sweep:sub mode:apply depth:depth + 1];
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
    UIWindow *win = [self appMainWindow];
    if (win && win.rootViewController.view) [self sweep:win.rootViewController.view mode:NO depth:0];
    [self applyOverlays];
    [self alertDone:@"已恢复背景原图"];
    NBLOG(@"[恢复] 背景");
}

#pragma mark - 调试：视图树导出

- (void)dumpViewTree {
    NSMutableString *out = [NSMutableString stringWithCapacity:4096];
    [out appendFormat:@"==== NinebotSkin %@ viewtree %@ ====\n", NB_VERSION, [NSDate date]];
    UIWindow *win = [self appMainWindow];
    if (win) [self dump:win.rootViewController.view to:out depth:0];
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self alertDone:[NSString stringWithFormat:@"已导出:\n%@", path]];
    NBLOG(@"[调试] 视图树导出 %lu 行", (unsigned long)out.length);
}

- (void)dump:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
    if (!view || depth > 9) return;
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@\n",
     [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha, (int)view.hidden,
     view.backgroundColor ? @"Y" : @"-"];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end
