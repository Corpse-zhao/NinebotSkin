#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>
#import <stdlib.h>

// ============================================================
// NinebotSkin v0.1.7 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
//
// v0.1.7 的关键认知修正（v0.1.5/0.1.6 都栽在这里）:
//   原车**不在**舞台图里！真机截图证明舞台上还叠着一层"原车模型"。
//   所以把车合成进舞台图，等于在 App 自己的车下面又画了一台，
//   表现为「两台车重叠」「原车盖在替换图上面」「白块露在车后面」。
//
//   现在的分工:
//     · 舞台图（背景层）→ 只负责背景图替换，绝不掺车辆，也绝不画白色遮罩
//     · 车视图（原车那一层，与舞台同尺寸的可见图层）→ 直接换掉它的 image
//   换车视图的 image 有个大好处：位置、缩放、下拉时的行为全部继承 App 自己的逻辑，
//   不需要我们猜。叠加时再按「原车主体包围盒」自动定位，导入即对齐。
//
// 页面结构（真机 viewtree ×4 实测，430×932）:
//   OuterScrollView(932, 会滚动) → UIView(430×983)
//       UIView(430×983, bg=Y)                       <- 舞台宿主
//         UIImageView {0,0,430,441.47}              <- 背景层
//         UIImageView ×N 同尺寸                      <- 原车模型所在的图层
//         UIView {0,391,430,50}
//         UITableView {0,0,430,900}                 <- 卡片列表，自己的滚动
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // 舞台宿主比例
static NSString * const kKeyBgRect    = @"nbskin_bg_rect";

static NSString * const kDefaultVehRect = @"0.21,0.2485,0.61,0.1981";

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

// 任意图片数据 -> PNG（兼容 HEIC/CMYK/带旋转），并回传像素尺寸
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

// ---------- 车辆图预处理：去白底 + 裁掉四周空白 ----------
// 用户选的图常常是「白底/带场景的产品图」，直接塞进车辆框会有两个毛病：
//   1) 图里大片留白 → 车在框里显得很小，看起来像"没替换"
//   2) 白底会跟着画上去 → 背后一圈白块
// 这里在落盘前一次性处理：把四边连通的近白像素抹成透明，再按不透明主体裁边。

static NSData *NBEncodePNG(CGImageRef img) {
    if (!img) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) return nil;
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? out : nil;
}

// 扫描线泛洪：从四边把连通的近白像素抹成透明。返回被抹掉的像素数。
// alpha 在这里被当成"已处理"标记：255 = 未处理，0 = 已抹掉。
static size_t NBStripWhite(uint8_t *p, int w, int h) {
    const int T = 243;
    size_t cap = (size_t)(w + h) * 8 + 1024;
    int32_t *sx = (int32_t *)malloc(sizeof(int32_t) * cap);
    int32_t *sy = (int32_t *)malloc(sizeof(int32_t) * cap);
    if (!sx || !sy) { free(sx); free(sy); return 0; }
    size_t sp = 0;

#define NB_IS_BG(q) ((q)[3] == 255 && (q)[0] >= T && (q)[1] >= T && (q)[2] >= T)
#define NB_PUSH(px, py) do { if (sp < cap) { sx[sp] = (px); sy[sp] = (py); sp++; } } while (0)

    for (int x = 0; x < w; x++) {
        if (NB_IS_BG(p + (size_t)x * 4)) NB_PUSH(x, 0);
        if (NB_IS_BG(p + ((size_t)(h - 1) * w + x) * 4)) NB_PUSH(x, h - 1);
    }
    for (int y = 0; y < h; y++) {
        if (NB_IS_BG(p + (size_t)y * w * 4)) NB_PUSH(0, y);
        if (NB_IS_BG(p + ((size_t)y * w + w - 1) * 4)) NB_PUSH(w - 1, y);
    }

    size_t filled = 0;
    while (sp > 0) {
        sp--;
        int x = sx[sp], y = sy[sp];
        uint8_t *row = p + (size_t)y * w * 4;
        if (!NB_IS_BG(row + (size_t)x * 4)) continue;
        int l = x, r = x;
        while (l - 1 >= 0 && NB_IS_BG(row + (size_t)(l - 1) * 4)) l--;
        while (r + 1 < w && NB_IS_BG(row + (size_t)(r + 1) * 4)) r++;
        for (int i = l; i <= r; i++) {
            uint8_t *q = row + (size_t)i * 4;
            q[0] = q[1] = q[2] = q[3] = 0;
            filled++;
        }
        for (int dy = -1; dy <= 1; dy += 2) {
            int ny = y + dy;
            if (ny < 0 || ny >= h) continue;
            uint8_t *nrow = p + (size_t)ny * w * 4;
            BOOL run = NO;
            for (int i = l; i <= r; i++) {
                BOOL bg = NB_IS_BG(nrow + (size_t)i * 4);
                if (bg && !run) { NB_PUSH(i, ny); run = YES; }
                else if (!bg) run = NO;
            }
        }
    }
#undef NB_IS_BG
#undef NB_PUSH
    free(sx); free(sy);
    return filled;
}

static CGRect NBOpaqueBounds(uint8_t *p, int w, int h) {
    int minX = w, minY = h, maxX = -1, maxY = -1;
    for (int y = 0; y < h; y++) {
        uint8_t *row = p + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            if (row[(size_t)x * 4 + 3] > 8) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    if (maxX < 0) return CGRectZero;
    return CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

// 输出：去白底 + 裁边后的 PNG
static NSData *NBPrepareVehiclePNG(NSData *data, CGSize *outPx, CGFloat *outTrim, BOOL *outStripped) {
    if (outTrim) *outTrim = 0.0;
    if (outStripped) *outStripped = NO;
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t ow = CGImageGetWidth(img), oh = CGImageGetHeight(img);
    if (outPx) *outPx = CGSizeMake(ow, oh);
    if (!ow || !oh) { CGImageRelease(img); return nil; }

    // 车辆图最终只会画在 ~800×600 的框里，超过 1600px 的一律先缩，省内存也省时间
    CGFloat sc = 1.0;
    if (MAX(ow, oh) > 1600) sc = 1600.0 / (CGFloat)MAX(ow, oh);
    size_t w = (size_t)lround((double)ow * sc), h = (size_t)lround((double)oh * sc);
    if (!w) w = 1;
    if (!h) h = 1;

    NSMutableData *buf = [NSMutableData dataWithLength:w * 4 * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(img); return nil; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGImageRelease(img);

    uint8_t *p = (uint8_t *)buf.mutableBytes;
    size_t px = w * h;
    BOOL opaque = YES;
    for (size_t i = 0; i < px; i++) { if (p[i * 4 + 3] < 250) { opaque = NO; break; } }

    if (opaque) {
        // 完全没有透明像素 → 很可能是白底图，试着把白底抹掉
        size_t filled = NBStripWhite(p, (int)w, (int)h);
        if (filled > px * 9 / 10) {
            // 几乎整张都被当成背景了（判断失误），回退到原图
            CGContextRelease(ctx);
            return NBPNGData(data, NULL);
        }
        if (filled > px / 100) { if (outStripped) *outStripped = YES; }
    }

    CGRect box = NBOpaqueBounds(p, (int)w, (int)h);
    CGImageRef full = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!full) return NBPNGData(data, NULL);

    CGRect use = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    if (!CGRectIsEmpty(box)) {
        CGFloat area = box.size.width * box.size.height;
        if (area >= (CGFloat)px * 0.06 && area <= (CGFloat)px * 0.995) {
            use = CGRectIntegral(CGRectInset(box, -box.size.width * 0.02, -box.size.height * 0.02));
            use = CGRectIntersection(use, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));
            if (CGRectIsNull(use) || use.size.width < 1 || use.size.height < 1)
                use = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
            else if (outTrim) *outTrim = 1.0 - area / ((CGFloat)px);
        }
    }

    NSData *out = nil;
    if (use.size.width < (CGFloat)w || use.size.height < (CGFloat)h) {
        CGImageRef cropped = CGImageCreateWithImageInRect(full, use);
        if (cropped) {
            out = NBEncodePNG(cropped);
            if (out && outPx) *outPx = CGSizeMake(CGImageGetWidth(cropped), CGImageGetHeight(cropped));
            CGImageRelease(cropped);
        }
    }
    if (!out) out = NBEncodePNG(full);
    CGImageRelease(full);
    return out;
}

// 图片不透明区域的归一化包围盒（左上原点，0~1）。用于把替换车对准原车主体。
static CGRect NBAlphaNormalizedBounds(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return CGRectZero;
    size_t ow = CGImageGetWidth(cg), oh = CGImageGetHeight(cg);
    if (!ow || !oh) return CGRectZero;
    CGFloat sc = 1.0;
    if (MAX(ow, oh) > 256) sc = 256.0 / (CGFloat)MAX(ow, oh);
    int w = (int)MAX((double)1, lround((double)ow * sc));
    int h = (int)MAX((double)1, lround((double)oh * sc));
    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)w * 4 * (NSUInteger)h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return CGRectZero;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGRect b = NBOpaqueBounds((uint8_t *)buf.mutableBytes, w, h);
    if (CGRectIsEmpty(b)) return CGRectZero;
    return CGRectMake(b.origin.x / w, b.origin.y / h, b.size.width / w, b.size.height / h);
}

// "x,y,w,h" -> 归一化矩形
static CGRect NBParseNormalizedRect(NSString *s) {
    NSArray *p = [s componentsSeparatedByString:@","];
    if (p.count < 4) return CGRectMake(0, 0, 1, 1);
    return CGRectMake([p[0] floatValue], [p[1] floatValue], [p[2] floatValue], [p[3] floatValue]);
}

// aspectFill / aspectFit 绘制
static void NBDrawImage(CGContextRef c, UIImage *img, CGRect rect, BOOL fill) {
    if (!img || CGRectIsEmpty(rect)) return;
    CGSize is = img.size;
    if (is.width <= 0 || is.height <= 0) return;
    CGFloat sx = rect.size.width / is.width;
    CGFloat sy = rect.size.height / is.height;
    CGFloat s = fill ? MAX(sx, sy) : MIN(sx, sy);
    CGFloat w = is.width * s, h = is.height * s;
    CGRect dst = CGRectMake(rect.origin.x + (rect.size.width - w) / 2.0,
                            rect.origin.y + (rect.size.height - h) / 2.0, w, h);
    if (fill) {
        CGContextSaveGState(c);
        CGContextClipToRect(c, rect);
        [img drawInRect:dst];
        CGContextRestoreGState(c);
    } else {
        [img drawInRect:dst];
    }
}

// ---------- 悬浮球独立的穿透窗口 ----------
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

// 舞台图（背景层）
@property (weak,   nonatomic) UIImageView *stageView;
@property (strong, nonatomic) UIImage *originalStageImage;
@property (assign, nonatomic) BOOL contentModeCaptured;
@property (assign, nonatomic) UIViewContentMode originalStageContentMode;
@property (strong, nonatomic) UIImage *stageImage;          // 我们给舞台设置的背景图

// 车视图（独立图层，浮在舞台之上）
@property (copy,   nonatomic) NSArray<UIView *> *carViews;
@property (strong, nonatomic) NSMapTable *carOriginals;     // view -> {image/mode/kind/contents/gravity}
@property (strong, nonatomic) UIImage *vehicleOverlayImage;
@property (assign, nonatomic) CGRect autoVehRect;           // 从原车主体自动推出来的位置

// 微调
@property (strong, nonatomic) UIImageView *adjustView;
@property (copy,   nonatomic) NSString *pickingSlot;
@property (copy,   nonatomic) NSString *adjustTarget;
@property (strong, nonatomic) UIPanGestureRecognizer *adjustPan;
@property (strong, nonatomic) UIPinchGestureRecognizer *adjustPinch;
@property (strong, nonatomic) NSTimer *watchdog;
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
    for (NSInteger i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self applyOverlays]; });
    }
}

- (void)startWatchdog {
    if (self.watchdog) return;
    __weak NBManager *weakSelf = self;
    // 0.6s：App 每次刷新数据都会重设 stage.image，要尽快补回
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        [weakSelf watchdogTick];
    }];
    NBLOG(@"[看门狗] 启动");
}

- (void)watchdogTick {
    if (![self hasAnyReplacement]) return;
    UIImageView *stage = [self findStageImageView];
    if (!stage) return;

    if (stage != self.stageView) {
        NBLOG(@"[看门狗] 舞台视图换了，重新应用");
        [self applyOverlays];
        return;
    }
    if (self.stageImage && stage.image != self.stageImage) {
        NBLOG(@"[看门狗] 舞台图被重置，重新应用");
        [self applyOverlays];
        return;
    }
    // 车视图被 App 换回原图 → 重新贴
    if (self.vehicleOverlayImage && self.carViews.count) {
        UIView *v = self.carViews.firstObject;
        UIImage *cur = nil;
        if ([v isKindOfClass:[UIImageView class]]) cur = ((UIImageView *)v).image;
        if ([v isKindOfClass:[UIImageView class]] && cur != self.vehicleOverlayImage) {
            NBLOG(@"[看门狗] 车视图被重置，重新贴图");
            [self applyOverlays];
        }
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
    [ac addAction:[UIAlertAction actionWithTitle:@"车辆图对准原车（重置位置）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self resetVehicleRect]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复车辆原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreVehicle]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复背景原图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [self restoreBackground]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"调试：导出视图树" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self dumpViewTree]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"调试：查车视图" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [self listCarViews]; }]];
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
        if (v == self.adjustView) continue;
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            CGSize b = iv.bounds.size;
            if (iv.image && !iv.hidden &&
                b.width >= ws.width * 0.85 &&
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

- (NSString *)storedPathForSlot:(NSString *)slot {
    NSString *key = [slot isEqualToString:@"veh"] ? kKeyVehPath : kKeyBgPath;
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!p.length || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

// 车辆框：用户微调过就用保存的；否则用「原车主体」自动推出来的；再否则用默认值
- (CGRect)vehicleRectInSize:(CGSize)sz {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyVehRect];
    CGRect n;
    if (raw.length) n = NBParseNormalizedRect(raw);
    else if (!CGRectIsEmpty(self.autoVehRect)) n = self.autoVehRect;
    else n = NBParseNormalizedRect(kDefaultVehRect);
    if (n.size.width <= 0 || n.size.height <= 0) n = NBParseNormalizedRect(kDefaultVehRect);
    return CGRectMake(n.origin.x * sz.width, n.origin.y * sz.height,
                      n.size.width * sz.width, n.size.height * sz.height);
}

// 车视图坐标系里的一屏尺寸（车挂在车视图上时就是车视图的 bounds）
- (CGSize)vehicleSpaceSize {
    UIView *v = self.carViews.count ? self.carViews.firstObject : nil;
    if (v && v.bounds.size.width > 1) return v.bounds.size;
    return self.stageView ? self.stageView.bounds.size : CGSizeZero;
}

#pragma mark - 舞台图（只负责背景）

- (UIImage *)renderStageImage:(CGSize)sz bg:(UIImage *)bg veh:(UIImage *)veh {
    if (sz.width < 1 || sz.height < 1) return nil;
    if (!bg && !veh) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 3.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *orig = self.originalStageImage;
    CGRect vr = [self vehicleRectInSize:[self vehicleSpaceSize]];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor whiteColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, sz.width, sz.height));
        if (bg) {
            NBDrawImage(c, bg, CGRectMake(0, 0, sz.width, sz.height), YES);
        } else if (orig) {
            NBDrawImage(c, orig, CGRectMake(0, 0, sz.width, sz.height), YES);
        }
        // 注意：这里不再画任何白色遮罩块 —— 原车不在舞台图里，
        // 之前那块纯白正是"背后一圈白底"的来源。
        if (veh) NBDrawImage(c, veh, vr, NO);
    }];
    NBLOG(@"[合成] 舞台 %@ bg=%d veh=%d vehRect=%@", NSStringFromCGSize(sz),
          bg != nil, veh != nil, NSStringFromCGRect(vr));
    return out;
}

// 透明背景的车辆层：尺寸与「车视图」一致，这样贴上去位置和缩放都天然对齐
- (UIImage *)renderVehicleOverlay:(UIImage *)veh size:(CGSize)sz {
    if (!veh || sz.width < 1 || sz.height < 1) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = 3.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    CGRect vr = [self vehicleRectInSize:sz];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        NBDrawImage(ctx.CGContext, veh, vr, NO);
    }];
    NBLOG(@"[合成] 车辆层 %@ vehRect=%@", NSStringFromCGSize(sz), NSStringFromCGRect(vr));
    return out;
}

#pragma mark - 车视图（原车所在的独立图层）

// 全窗口找「和舞台同尺寸、可见、带图像」的视图 —— 就是 App 画原车的那一层
- (NSArray<UIView *> *)visibleCarViewsForStage:(UIImageView *)stage {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    UIWindow *win = [self appMainWindow];
    if (!win || !stage) return out;
    CGSize s = stage.bounds.size;
    if (s.width < 1) return out;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win.rootViewController.view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == stage || v == self.adjustView) continue;
        if (v != self.ballWindow && ![v isKindOfClass:[UIWindow class]]) {
            CGSize b = v.bounds.size;
            BOOL same = (fabs(b.width - s.width) <= 8.0 && fabs(b.height - s.height) <= 8.0);
            if (same && !v.hidden && v.alpha > 0.05) {
                BOOL has = NO;
                if ([v isKindOfClass:[UIImageView class]]) has = (((UIImageView *)v).image != nil);
                else has = (v.layer.contents != nil);
                if (has) [out addObject:v];
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return out;
}

- (void)applyVehicleImage:(UIImage *)veh toView:(UIView *)v {
    if (!v || !veh) return;
    if (!self.carOriginals) self.carOriginals = [NSMapTable weakToStrongObjectsMapTable];
    UIImage *ov = [self renderVehicleOverlay:veh size:v.bounds.size];
    if (!ov) return;
    self.vehicleOverlayImage = ov;

    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (![self.carOriginals objectForKey:v]) {
            rec[@"kind"] = @"img";
            if (iv.image) rec[@"image"] = iv.image;
            rec[@"mode"] = @(iv.contentMode);
            [self.carOriginals setObject:rec forKey:v];
            NBLOG(@"[车视图] 记录原图 %@ mode=%ld",
                  iv.image ? NSStringFromCGSize(iv.image.size) : @"nil", (long)iv.contentMode);
        }
        iv.image = ov;
        // 车辆层和视图同尺寸，用 AspectFill 只是为了保证 1:1 铺满、不会被拉伸
        iv.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        if (![self.carOriginals objectForKey:v]) {
            rec[@"kind"] = @"layer";
            if (v.layer.contents) rec[@"contents"] = v.layer.contents;
            rec[@"gravity"] = v.layer.contentsGravity ?: @"";
            [self.carOriginals setObject:rec forKey:v];
            NBLOG(@"[车视图] 记录 layer contents gravity=%@", v.layer.contentsGravity);
        }
        v.layer.contents = (__bridge id)ov.CGImage;
        v.layer.contentsGravity = kCAGravityResizeAspect;
    }
}

- (void)restoreCarViews {
    if (!self.carOriginals) return;
    for (id key in self.carOriginals) {
        NSDictionary *rec = [self.carOriginals objectForKey:key];
        if (![key isKindOfClass:[UIView class]]) continue;
        UIView *v = (UIView *)key;
        NSString *kind = rec[@"kind"];
        if ([kind isEqualToString:@"img"] && [v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            iv.image = rec[@"image"];
            iv.contentMode = (UIViewContentMode)[rec[@"mode"] integerValue];
        } else if ([kind isEqualToString:@"layer"]) {
            v.layer.contents = rec[@"contents"];
            NSString *g = rec[@"gravity"];
            if (g.length) v.layer.contentsGravity = g;
        }
    }
    [self.carOriginals removeAllObjects];
    self.vehicleOverlayImage = nil;
    NBLOG(@"[车视图] 已还原");
}

- (void)restoreStage {
    UIImageView *stage = self.stageView ?: [self findStageImageView];
    if (stage && self.stageImage && stage.image == self.stageImage) {
        if (self.originalStageImage) stage.image = self.originalStageImage;
        if (self.contentModeCaptured) stage.contentMode = self.originalStageContentMode;
        NBLOG(@"[舞台] 已还原原图");
    }
    self.stageImage = nil;
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win) return;
    UIImageView *stage = [self findStageImageView];
    if (!stage) return;
    self.stageView = stage;

    NSString *bgPath = [self storedPathForSlot:@"bg"];
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    UIImage *vehImg = vehPath ? [UIImage imageWithContentsOfFile:vehPath] : nil;

    // 1) 找车视图，并用「原车主体的包围盒」自动定位替换车（用户微调过则优先用户值）
    self.carViews = [self visibleCarViewsForStage:stage];
    self.autoVehRect = CGRectZero;
    if (self.carViews.count) {
        UIView *c0 = self.carViews.firstObject;
        UIImage *carImg = nil;
        if ([c0 isKindOfClass:[UIImageView class]]) carImg = ((UIImageView *)c0).image;
        CGRect nb = carImg ? NBAlphaNormalizedBounds(carImg) : CGRectZero;
        if (!CGRectIsEmpty(nb)) self.autoVehRect = nb;
        NBLOG(@"[车视图] %lu 个，首个=%@ 原图=%@ 主体框=%@", (unsigned long)self.carViews.count,
              NSStringFromClass([c0 class]),
              carImg ? NSStringFromCGSize(carImg.size) : @"nil",
              CGRectIsEmpty(nb) ? @"nil" : NSStringFromCGRect(nb));
    }

    BOOL onCarView = (self.carViews.count > 0 && vehImg != nil);

    // 2) 舞台：只负责背景
    if (!self.originalStageImage && stage.image && stage.image != self.stageImage) {
        self.originalStageImage = stage.image;
        self.originalStageContentMode = stage.contentMode;
        self.contentModeCaptured = YES;
        NBLOG(@"[舞台] 捕获原图 %@ mode=%ld",
              NSStringFromCGSize(stage.image.size), (long)stage.contentMode);
    }

    if (bgImg || (vehImg && !onCarView)) {
        if (stage.image != self.stageImage || !self.stageImage) {
            UIImage *img = [self renderStageImage:stage.bounds.size
                                               bg:bgImg
                                              veh:(onCarView ? nil : vehImg)];
            if (img) {
                self.stageImage = img;
                stage.image = img;
                // 保持 App 自己的 contentMode：下拉怎么动就怎么动，不额外放大
                if (self.contentModeCaptured) stage.contentMode = self.originalStageContentMode;
            }
        }
    } else if (self.stageImage) {
        [self restoreStage];
    }

    // 3) 车辆：挂到车视图上（位置/缩放全部继承 App 自己的布局）
    if (onCarView) {
        for (UIView *v in self.carViews) [self applyVehicleImage:vehImg toView:v];
    } else if (!vehImg) {
        [self restoreCarViews];
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

        BOOL isVeh = [slot isEqualToString:@"veh"];
        CGSize px = CGSizeZero;
        CGFloat trim = 0.0;
        BOOL stripped = NO;
        NSData *png = isVeh ? NBPrepareVehiclePNG(data, &px, &trim, &stripped)
                            : NBPNGData(data, &px);
        BOOL ok = NO;
        NSString *savedPath = nil;
        if (png.length) {
            NSString *path = [NBLogDir() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.png", slot]];
            ok = [png writeToFile:path atomically:YES];
            savedPath = path;
        }
        NBLOG(@"[选图] slot=%@ 原始%luB -> png%luB %.0fx%.0f 去白底=%d 裁边=%.0f%% ok=%d",
              slot, (unsigned long)data.length, (unsigned long)png.length,
              px.width, px.height, (int)stripped, trim * 100.0, (int)ok);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                NSString *key = isVeh ? kKeyVehPath : kKeyBgPath;
                [[NSUserDefaults standardUserDefaults] setObject:savedPath forKey:key];
                [self applyOverlays];
                [self scheduleReapply];
                NSString *label = isVeh ? @"车辆图片" : @"背景图片";
                NSMutableString *note = [NSMutableString string];
                if (stripped) [note appendString:@"（已自动去掉白底）"];
                if (trim > 0.05) [note appendFormat:@"（已裁掉周围 %.0f%% 空白）", trim * 100.0];
                if (isVeh) [note appendString:@"\n位置/大小不对就点悬浮球 → 微调车辆图"];
                [self alertDone:[NSString stringWithFormat:@"已替换%@\n%@×%@ px%@",
                                 label, @((NSInteger)px.width), @((NSInteger)px.height), note]];
            } else {
                [self alertDone:@"图片解析失败（格式特殊），请换一张"];
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

#pragma mark - 微调车辆位置

- (void)beginAdjust:(NSString *)target {
    UIImageView *stage = [self findStageImageView];
    if (!stage) { [self alertDone:@"没找到车辆舞台区域，请回到车控页再试"]; return; }
    if (![self storedPathForSlot:@"veh"]) { [self alertDone:@"还没有替换车辆图片"]; return; }

    self.stageView = stage;
    self.carViews = [self visibleCarViewsForStage:stage];
    UIView *host = self.carViews.count ? self.carViews.firstObject : stage;
    if (!self.adjustView) {
        self.adjustView = [UIImageView new];
        self.adjustView.contentMode = UIViewContentModeScaleAspectFit;
    }
    NSString *p = [self storedPathForSlot:@"veh"];
    self.adjustView.image = [UIImage imageWithContentsOfFile:p];
    self.adjustView.frame = [self vehicleRectInSize:host.bounds.size];
    self.adjustView.userInteractionEnabled = YES;
    self.adjustView.layer.borderWidth = 1.5;
    self.adjustView.layer.borderColor = [UIColor systemBlueColor].CGColor;

    if (!self.adjustPan) {
        self.adjustPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPanned:)];
        self.adjustPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPinched:)];
    }
    if (self.adjustPan.view) [self.adjustPan.view removeGestureRecognizer:self.adjustPan];
    if (self.adjustPinch.view) [self.adjustPinch.view removeGestureRecognizer:self.adjustPinch];
    [self.adjustView addGestureRecognizer:self.adjustPan];
    [self.adjustView addGestureRecognizer:self.adjustPinch];

    [host addSubview:self.adjustView];
    self.adjustTarget = target;
    [self.ballButton setTitle:@"✓" forState:UIControlStateNormal];
    [self unhideBall];
    NBLOG(@"[微调] 进入 frame=%@ host=%@", NSStringFromCGRect(self.adjustView.frame),
          NSStringFromClass([host class]));
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
    UIView *v = self.adjustView;
    UIView *host = v.superview;
    if (v && host) {
        CGFloat W = host.bounds.size.width, H = host.bounds.size.height;
        if (W > 1 && H > 1) {
            CGRect f = v.frame;
            NSString *rect = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                              f.origin.x / W, f.origin.y / H, f.size.width / W, f.size.height / H];
            [[NSUserDefaults standardUserDefaults] setObject:rect forKey:kKeyVehRect];
            NBLOG(@"[微调] 保存 rect=%@", rect);
        }
    }
    [v removeFromSuperview];
    self.adjustTarget = nil;
    [self.ballButton setTitle:@"🛴" forState:UIControlStateNormal];
    self.vehicleOverlayImage = nil;
    self.stageImage = nil;      // 强制重新渲染
    [self applyOverlays];
    [self scheduleReapply];
    [self alertDone:@"车辆图位置已保存"];
}

- (void)resetVehicleRect {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
    self.vehicleOverlayImage = nil;
    self.stageImage = nil;
    [self applyOverlays];
    [self scheduleReapply];
    [self alertDone:@"车辆图已对准原车位置"];
}

#pragma mark - 恢复

- (void)restoreVehicle {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehPath];
    self.vehicleOverlayImage = nil;
    self.stageImage = nil;
    [self applyOverlays];
    if (![self hasAnyReplacement]) [self restoreOriginalStage];
    [self alertDone:@"已恢复车辆原图"];
    NBLOG(@"[恢复] 车辆图");
}

- (void)restoreBackground {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgPath];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgRect];
    self.stageImage = nil;
    [self applyOverlays];
    if (![self hasAnyReplacement]) [self restoreOriginalStage];
    [self alertDone:@"已恢复背景原图"];
    NBLOG(@"[恢复] 背景");
}

- (void)restoreOriginalStage {
    [self restoreStage];
    [self restoreCarViews];
    NBLOG(@"[恢复] 舞台原图已还回");
}

#pragma mark - 调试

- (void)listCarViews {
    UIImageView *stage = [self findStageImageView];
    NSArray<UIView *> *cars = [self visibleCarViewsForStage:stage];
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"舞台 %@ %@\n车视图 %lu 个:",
     stage ? NSStringFromClass([stage class]) : @"nil",
     stage ? NSStringFromCGRect(stage.bounds) : @"-", (unsigned long)cars.count];
    for (UIView *v in cars) {
        UIImage *im = [v isKindOfClass:[UIImageView class]] ? ((UIImageView *)v).image : nil;
        [m appendFormat:@"\n· %@ %@ img=%@", NSStringFromClass([v class]),
         NSStringFromCGRect(v.bounds), im ? NSStringFromCGSize(im.size) : @"layer"];
    }
    NBLOG(@"[调试] %@", [m stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    [self alertDone:m];
}

- (void)dumpViewTree {
    NSMutableString *out = [NSMutableString stringWithCapacity:8192];
    [out appendFormat:@"==== NinebotSkin %@ viewtree %@ ====\n", NB_VERSION, [NSDate date]];
    UIWindow *win = [self appMainWindow];
    if (win) {
        [out appendFormat:@"[window] %@ bounds=%@\n", NSStringFromClass([win class]),
         NSStringFromCGRect(win.bounds)];
        UIImageView *stage = [self findStageImageView];
        NSString *stageCls = stage ? NSStringFromClass([stage class]) : @"nil";
        NSString *stageFrame = stage ? NSStringFromCGRect(stage.frame) : @"-";
        NSString *stageImg = (stage && stage.image) ? NSStringFromCGSize(stage.image.size) : @"nil";
        BOOL isOurs = (stage && stage.image && stage.image == self.stageImage);
        [out appendFormat:@"[stage] %@ frame=%@ img=%@ (ours=%d) autoVehRect=%@\n",
         stageCls, stageFrame, stageImg, (int)isOurs,
         CGRectIsEmpty(self.autoVehRect) ? @"nil" : NSStringFromCGRect(self.autoVehRect)];
        for (UIView *v in self.carViews) {
            UIImage *im = [v isKindOfClass:[UIImageView class]] ? ((UIImageView *)v).image : nil;
            [out appendFormat:@"[carview] %@ frame=%@ img=%@ ours=%d\n",
             NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
             im ? NSStringFromCGSize(im.size) : @"layer",
             (int)(im && im == self.vehicleOverlayImage)];
        }
        [self dump:win.rootViewController.view to:out depth:0];
    }
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self alertDone:[NSString stringWithFormat:@"已导出:\n%@", path]];
    NBLOG(@"[调试] 导出 %lu 字节", (unsigned long)out.length);
}

- (void)dump:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
    if (!view || depth > 16) return;
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@ img=%@ %@\n",
     [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha, (int)view.hidden,
     view.backgroundColor ? @"Y" : @"-",
     view.layer.contents ? @"Y" : @"-",
     (view == self.adjustView ? @"<ADJUST>" : @"")];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end
