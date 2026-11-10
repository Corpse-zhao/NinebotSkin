#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>

// ============================================================
// NinebotSkin v0.1.2 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
//
// 页面真实结构（真机 viewtree 实测，430×932）:
//   UIView (430×983, bg=Y)          <- 页面容器，overlay 放这里
//     UIImageView {0,0,430,441.47}  <- 「ninebot 舞台图」：水印 + 原车烘在同一张图里
//     UIImageView ×2 同尺寸（hidden）
//     UIView {0,391,430,50}
//     UITableView {0,0,430,900}     <- 卡片列表（背景透明，cells 从 y=666 起）
//
// v0.1.2:
//   1. 背景图铺满舞台层，插在 TableView 之下、舞台图之上
//      （旧版塞 window index0，被这张不透明舞台图整张盖住 => "不生效"）
//   2. 车辆图默认对准原车位置（容器比例 0.21,0.2485,0.61,0.1981）
//   3. 替换车辆图/背景图后，把原舞台图 alpha=0 => 原车图案隐藏
//   4. 取消全屏 alpha 击杀（副作用大且已不需要）
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // 页面容器比例
static NSString * const kKeyBgRect    = @"nbskin_bg_rect";  // 页面容器比例（空=跟随舞台图）

static NSString * const kDefaultVehRect = @"0.21,0.2485,0.61,0.1981";
static NSString * const kDefaultBgRect  = @"0,0,1,0.4491";   // 441.47/983

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
@property (strong, nonatomic) UIImageView *bgView;
@property (strong, nonatomic) UIImageView *vehView;
@property (strong, nonatomic) UIWindow *hostWindow;
@property (copy,   nonatomic) NSString *pickingSlot;
@property (copy,   nonatomic) NSString *adjustTarget;  // @"veh" / @"bg"
@property (strong, nonatomic) UIPanGestureRecognizer *adjustPan;
@property (strong, nonatomic) UIPinchGestureRecognizer *adjustPinch;
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
    });
}

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

#pragma mark - 页面结构探测

- (UIView *)findPageHostWithTable:(UITableView **)outTable stage:(CGRect *)outStage {
    UIWindow *win = [self appMainWindow];
    if (!win || !win.rootViewController.view) return nil;
    CGSize winSize = win.bounds.size;

    UITableView *found = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win.rootViewController.view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]] &&
            !v.hidden && v.alpha > 0.5 &&
            v.bounds.size.height >= winSize.height * 0.75) {
            found = (UITableView *)v;
            break;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    if (!found || !found.superview) return nil;

    UIView *host = found.superview;
    UIImageView *stage = nil;
    for (UIView *s in host.subviews) {
        if (![s isKindOfClass:[UIImageView class]]) continue;
        UIImageView *iv = (UIImageView *)s;
        if (!iv.image || iv.hidden || iv.alpha < 0.5) continue;
        if (iv.bounds.size.width < host.bounds.size.width * 0.85) continue;
        if (iv.bounds.size.height < winSize.height * 0.20) continue;
        if (iv.bounds.size.height > winSize.height * 0.65) continue;
        if (!stage || iv.bounds.size.height > stage.bounds.size.height) stage = iv;
    }

    if (outTable) *outTable = found;
    if (outStage) *outStage = stage ? stage.frame
                                    : CGRectMake(0, 0, host.bounds.size.width,
                                                 host.bounds.size.height * 0.4491);
    NBLOG(@"[结构] 容器 %@ %.0fx%.0f 舞台 %@",
          NSStringFromClass([host class]), host.bounds.size.width, host.bounds.size.height,
          NSStringFromCGRect(outStage ? *outStage : CGRectZero));
    return host;
}

// 原车图案和 ninebot 水印烘在同一张舞台图里 => 隐藏原车 = 舞台图 alpha 0
- (void)setStageImagesHidden:(BOOL)hidden inHost:(UIView *)host stage:(CGRect)stageFrame {
    if (!host) return;
    CGSize s = host.bounds.size;
    for (UIView *v in host.subviews) {
        if (![v isKindOfClass:[UIImageView class]]) continue;
        UIImageView *iv = (UIImageView *)v;
        if (!iv.image) continue;
        if (iv.bounds.size.width < s.width * 0.85) continue;
        if (fabs(iv.bounds.size.height - stageFrame.size.height) > 2.0) continue;
        if (hidden) {
            if (!objc_getAssociatedObject(iv, &NBOrigAlphaKey))
                objc_setAssociatedObject(iv, &NBOrigAlphaKey, @(iv.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            iv.alpha = 0.0;
        } else {
            id oa = objc_getAssociatedObject(iv, &NBOrigAlphaKey);
            if (oa) {
                iv.alpha = [oa floatValue];
                objc_setAssociatedObject(iv, &NBOrigAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    NBLOG(@"[舞台] %@", hidden ? @"原车/水印图层已隐藏" : @"原车/水印图层已恢复");
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
                [self scheduleReapply];
                if ([slot isEqualToString:@"veh"]) {
                    [self alertDone:@"已替换车辆图片\n原车图案已隐藏，可用「微调车辆图」修正位置"];
                } else {
                    [self alertDone:@"已替换背景（ninebot 区域）"];
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

#pragma mark - 位置与放置

- (CGRect)frameForRectKey:(NSString *)key default:(NSString *)def inHost:(UIView *)host {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!raw.length) raw = def;
    if (!raw.length) return CGRectZero;
    NSArray *p = [raw componentsSeparatedByString:@","];
    CGFloat fx = p.count > 0 ? [p[0] floatValue] : 0.0;
    CGFloat fy = p.count > 1 ? [p[1] floatValue] : 0.0;
    CGFloat fw = p.count > 2 ? [p[2] floatValue] : 1.0;
    CGFloat fh = p.count > 3 ? [p[3] floatValue] : 1.0;
    CGSize s = host.bounds.size;
    return CGRectMake(fx * s.width, fy * s.height, fw * s.width, fh * s.height);
}

- (void)placeView:(UIView *)v inHost:(UIView *)host below:(UIView *)table {
    if (!v || !host) return;
    if (v.superview != host) {
        [v removeFromSuperview];
        [host addSubview:v];
    }
    if (table && table.superview == host && v != table) {
        [host insertSubview:v belowSubview:table];
    } else {
        [host bringSubviewToFront:v];
    }
}

- (NSString *)storedPathForSlot:(NSString *)slot {
    NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!p.length || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win) return;
    self.hostWindow = win;

    UITableView *table = nil;
    CGRect stageFrame = CGRectZero;
    UIView *host = [self findPageHostWithTable:&table stage:&stageFrame];

    NSString *bgPath = [self storedPathForSlot:@"bg"];
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    UIImage *vehImg = vehPath ? [UIImage imageWithContentsOfFile:vehPath] : nil;

    // 只要替换了任一图层，就把「原车+水印」舞台图隐藏，避免原车重叠
    [self setStageImagesHidden:(bgImg != nil || vehImg != nil) inHost:host stage:stageFrame];

    // ---- 背景 ----
    if (bgImg) {
        if (!self.bgView) {
            self.bgView = [UIImageView new];
            self.bgView.userInteractionEnabled = NO;
            self.bgView.contentMode = UIViewContentModeScaleAspectFill;
            self.bgView.clipsToBounds = YES;
            self.bgView.backgroundColor = [UIColor whiteColor]; // 白底，贴合「白色区域」
        }
        self.bgView.image = bgImg;
        if (host) {
            NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgRect];
            self.bgView.frame = custom.length ? [self frameForRectKey:kKeyBgRect default:kDefaultBgRect inHost:host]
                                              : stageFrame;
            if (![self.adjustTarget isEqualToString:@"bg"]) {
                [self placeView:self.bgView inHost:host below:table];
            }
        } else if (self.bgView.superview != win) {
            self.bgView.frame = win.bounds;
            [win insertSubview:self.bgView atIndex:0];
            NBLOG(@"[overlay] 未找到页面容器，退化 window 底层");
        }
    } else if (self.bgView) {
        [self.bgView removeFromSuperview];
    }

    // ---- 车辆 ----
    if (vehImg) {
        if (!self.vehView) {
            self.vehView = [UIImageView new];
            self.vehView.userInteractionEnabled = NO;
            self.vehView.contentMode = UIViewContentModeScaleAspectFit;
        }
        self.vehView.image = vehImg;
        if (host) {
            if (![self.adjustTarget isEqualToString:@"veh"]) {
                self.vehView.frame = [self frameForRectKey:kKeyVehRect default:kDefaultVehRect inHost:host];
                [self placeView:self.vehView inHost:host below:table];
            }
        } else {
            if (![self.adjustTarget isEqualToString:@"veh"]) {
                self.vehView.frame = [self frameForRectKey:kKeyVehRect default:kDefaultVehRect inHost:win];
            }
            [win addSubview:self.vehView];
        }
    } else if (self.vehView) {
        [self.vehView removeFromSuperview];
    }
}

#pragma mark - 现场微调

- (void)beginAdjust:(NSString *)target {
    UIView *v = [target isEqualToString:@"bg"] ? self.bgView : self.vehView;
    if (!v) { [self alertDone:[target isEqualToString:@"bg"] ? @"还没有替换背景图片" : @"还没有替换车辆图片"]; return; }
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
    [v.superview bringSubviewToFront:v]; // 编辑期间置顶，否则被 TableView 抢触摸
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
    UIView *v = [self adjustTarget isEqualToString:@"bg"] ? self.bgView : self.vehView;
    UIView *host = v.superview;
    NSString *target = self.adjustTarget ?: @"veh";
    if (v && host) {
        CGFloat W = host.bounds.size.width, H = host.bounds.size.height;
        if (W > 1 && H > 1) {
            CGRect f = v.frame;
            NSString *rect = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                              f.origin.x / W, f.origin.y / H, f.size.width / W, f.size.height / H];
            [[NSUserDefaults standardUserDefaults] setObject:rect
                                                      forKey:[target isEqualToString:@"bg"] ? kKeyBgRect : kKeyVehRect];
            NBLOG(@"[微调] 保存 %@ = %@", target, rect);
        }
    }
    v.userInteractionEnabled = NO;
    v.layer.borderWidth = 0.0;
    self.adjustTarget = nil;
    [self.ballButton setTitle:@"🛴" forState:UIControlStateNormal];
    [self applyOverlays];
    [self alertDone:[target isEqualToString:@"bg"] ? @"背景区域已保存" : @"车辆图位置已保存"];
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
        [self dump:win.rootViewController.view to:out depth:0];
    }
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self alertDone:[NSString stringWithFormat:@"已导出:\n%@", path]];
    NBLOG(@"[调试] 导出 %lu 字节", (unsigned long)out.length);
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
