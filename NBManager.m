#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>
#import <stdlib.h>

// ============================================================
// NinebotSkin v0.1.11 —— 九号出行 车辆图/背景图替换（图片版）
// 注入目标: cn.ninebot.segway
//
// 真机 viewtree(4) 把结构钉死了:
//   NBBaseUIKit.MotorDetailShortCutsCell {430, 666.67}
//     UIView {0, 103}, {430, 563.67}
//       UIButton {76.67, 106.33}, {276.67, 242}     <- 爱车按钮（点击进车辆详情）
//         UIImageView {0, 0}, {276.67, 242} img=Y   <- **原车就是这张图**
//       QGVAPWrapView {0, 0}, {430, 441.33}         <- ninebot 水印动画（VAP）
//
// 两条路径分工明确，各自都是「已经验证可见」的：
//   背景 = 改写舞台图自己的 image（v0.1.5 起一直有效）
//   车辆 = 在原车按钮的 superview 最上层贴一个 UIImageView，然后藏掉原车图
//          （微调框一直就是这么挂的，实测可见；而 insertSubview:aboveSubview:
//            只插到紧邻下层，会被同级视图盖住 —— 这就是之前"贴了看不见"的原因）
//
// 车辆图层是按钮的子视图：
//   · 跟着 App 布局走 → 下拉放大、滚动、换页都和原车完全同步，不用自己算
//   · contentMode = ScaleAspectFit → 等比缩放，永不拉伸
//   · userInteractionEnabled = NO → 点击穿透，进车辆详情的功能保住
//   · 默认 frame = 原车图 frame（微调时存的是相对原车的比例，默认 0,0,1,1）
// ============================================================

static NSString * const kTargetBundle = @"cn.ninebot.segway";
static NSString * const kKeyBgPath    = @"nbskin_bg_path";
static NSString * const kKeyVehPath   = @"nbskin_veh_path";
static NSString * const kKeyVehRect   = @"nbskin_veh_rect"; // 相对「原车视图 frame」的比例
static NSString * const kKeyBgRect    = @"nbskin_bg_rect";

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

// ---------- 反闪：把「原车图被 App 重新显示」这件事同步拦下来 ----------
// 切页面 / cell 复用时，App 会把原车图的 hidden 设回 NO。看门狗哪怕 0.15s 补一次，
// 也总有一帧原车。这里直接接管 UIView 的 -setHidden:，对这一张图当场改回 YES，
// 做到「零帧」。只拦「设为可见」这一种情况，其余全部原样透传。
static __weak UIView *gNBCarGuard = nil;
static IMP gNBOrigSetHidden = NULL;

static void NBCarSetHidden(UIView *self, SEL _cmd, BOOL hidden) {
    if (!hidden) {
        UIView *guard = gNBCarGuard;
        if (guard && guard == self) hidden = YES;
    }
    if (gNBOrigSetHidden) ((void (*)(id, SEL, BOOL))gNBOrigSetHidden)(self, _cmd, hidden);
}

@interface NBManager () <PHPickerViewControllerDelegate>
@property (strong, nonatomic) UIWindow *ballWindow;
@property (strong, nonatomic) UIButton *ballButton;

// 舞台图（背景层）
@property (weak,   nonatomic) UIImageView *stageView;
@property (strong, nonatomic) UIImage *originalStageImage;
@property (assign, nonatomic) BOOL contentModeCaptured;
@property (assign, nonatomic) UIViewContentMode originalStageContentMode;
@property (strong, nonatomic) UIImage *stageImage;          // 我们给舞台设置的背景图
@property (copy,   nonatomic) NSString *bgStamp;             // 渲染这张背景时用的文件指纹

// 车：原车视图（只用来定位 / 当挂载点）+ 我们贴上去的车辆图层
@property (weak,   nonatomic) UIView *carView;             // 爱车按钮里的那个 UIImageView
@property (strong, nonatomic) UIImageView *vehicleView;    // 我们自己贴的车辆图层（挂在 carView.superview 最上层）
@property (strong, nonatomic) UIImage *originalCarImage;   // 原车图
@property (assign, nonatomic) BOOL carStateSaved;
@property (assign, nonatomic) BOOL carWasHidden;
@property (assign, nonatomic) CGFloat carWasAlpha;

// 微调
@property (assign, nonatomic) BOOL adjusting;
@property (copy,   nonatomic) NSString *pickingSlot;
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
    [self installHiddenGuard];
    [self setupRound:0];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onForeground)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

// 接管 -[UIView setHidden:]，用来「原车图被设回可见」时同步纠正（见文件上方 NBCarSetHidden）
- (void)installHiddenGuard {
    if (gNBOrigSetHidden) return;
    Method m = class_getInstanceMethod([UIView class], @selector(setHidden:));
    if (!m) { NBLOG(@"[反闪] 没找到 setHidden:，退回看门狗轮询"); return; }
    gNBOrigSetHidden = method_setImplementation(m, (IMP)NBCarSetHidden);
    NBLOG(@"[反闪] 已接管 UIView -setHidden:");
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
    // 0.2s：切页面时 App 会重设 hidden / 重设 stage.image，要尽快补回。
    // tick 本身很轻（不遍历视图树，只在舞台图丢失时才扫描），所以 0.2s 不会拖帧。
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        [weakSelf watchdogTick];
    }];
    NBLOG(@"[看门狗] 启动（0.2s）");
}

- (void)watchdogTick {
    if (![self hasAnyReplacement]) return;

    // 舞台图还在就用缓存的那个，不要每 0.2s 扫一遍整棵视图树
    UIImageView *stage = self.stageView;
    if (!stage || !stage.window) {
        stage = [self findStageImageView];
        if (!stage) return;
        if (stage != self.stageView) {
            NBLOG(@"[看门狗] 舞台视图换了，重新应用");
            [self applyOverlays];
            return;
        }
    }
    if (self.stageImage && stage.image != self.stageImage) {
        NBLOG(@"[看门狗] 舞台图被重置，重新应用");
        [self applyOverlays];
        return;
    }

    // 车：图层丢了 / 被换父视图 → 重挂；只是位置变了 → 跟着布局走（不重算图像）
    if (self.vehicleView) {
        UIView *car = self.carView;
        UIImageView *vv = self.vehicleView;
        if (!car || !car.superview || !car.window) {
            NBLOG(@"[看门狗] 找不到原车视图，重新应用");
            [self applyOverlays];
            return;
        }
        if (vv.superview != car.superview || !vv.window) {
            NBLOG(@"[看门狗] 车辆图层掉了，重新挂上");
            [self applyOverlays];
            return;
        }
        if (vv.image == nil) {
            NBLOG(@"[看门狗] 车辆图层图被清空，重新应用");
            [self applyOverlays];
            return;
        }
        // 被 App 的 layoutSubviews 压到下面去了 → 拎回最上层
        if (vv.superview.subviews.lastObject != vv) {
            [vv.superview bringSubviewToFront:vv];
            NBLOG(@"[看门狗] 车辆图层被压到下层，已拎回最上");
        }
        if (!self.adjusting) {
            CGRect want = [self vehicleFrameForCarView:car];
            if (!CGRectEqualToRect(want, vv.frame)) vv.frame = want;
        }
        // 兜底：万一 setHidden: 没拦住（UIKit 内部直接改 layer.hidden 之类）
        if (!car.hidden && self.carStateSaved) car.hidden = YES;
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
    if (self.adjusting) { [self finishAdjust]; return; }
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
        if (v == self.vehicleView) continue;
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

// 车辆图相对「原车视图」的比例框。默认 0,0,1,1 = 正好盖住原车图。
- (CGRect)vehicleNormRect {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyVehRect];
    if (!raw.length) return CGRectMake(0, 0, 1, 1);
    CGRect n = NBParseNormalizedRect(raw);
    if (n.size.width <= 0.01 || n.size.height <= 0.01) return CGRectMake(0, 0, 1, 1);
    return n;
}

// 图片文件的指纹（大小 + 修改时间）。
// 为什么需要它：舞台图的 image 每次都是同一个文件名 <slot>.png，
// 只比「image 指针是不是我上次设的那张」会导致「换了图但不重画」——
// 换了背景必须重启才生效就是这么来的。比指纹才能真正发现内容变了。
- (NSString *)stampForPath:(NSString *)p {
    if (!p.length) return nil;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    if (!a) return nil;
    NSNumber *sz = a[NSFileSize];
    NSDate *md = a[NSFileModificationDate];
    if (![sz isKindOfClass:[NSNumber class]]) return nil;
    return [NSString stringWithFormat:@"%llu|%.4f",
            sz.unsignedLongLongValue, md ? md.timeIntervalSince1970 : 0.0];
}

// 车辆图层在「原车视图的 superview」里的 frame。
// 用 carView.frame（不是 bounds）是因为图层和原车是兄弟视图，同一坐标系。
- (CGRect)vehicleFrameForCarView:(UIView *)v {
    if (!v) return CGRectZero;
    CGRect n = [self vehicleNormRect];
    CGSize bs = v.bounds.size;
    CGRect f = v.frame;
    return CGRectMake(f.origin.x + n.origin.x * bs.width,
                      f.origin.y + n.origin.y * bs.height,
                      n.size.width * bs.width, n.size.height * bs.height);
}

#pragma mark - 舞台图（只负责背景）
// 背景就是「把舞台图自己的 image 换成一张新合成的图」—— v0.1.5 起一直有效。
// 白底打底 + aspectFill，保证任何比例的图都铺满、不留白块。
- (UIImage *)renderStageImage:(CGSize)sz bg:(UIImage *)bg {
    if (sz.width < 1 || sz.height < 1 || !bg) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 3.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor whiteColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, sz.width, sz.height));
        NBDrawImage(c, bg, CGRectMake(0, 0, sz.width, sz.height), YES);
    }];
    NBLOG(@"[合成] 舞台 %@ 背景 %@", NSStringFromCGSize(sz), NSStringFromCGSize(bg.size));
    return out;
}

#pragma mark - 车视图（只用来定位原车在哪，不改它）

// 原车在真机上的真实结构（viewtree 实测）:
//   UIButton {{76.67, 106.33}, {276.67, 242}}
//     UIImageView {{0, 0}, {276.67, 242}} img=Y      <- 就是它，点击进车辆详情
// 所以不能靠"和舞台同尺寸"去找，要靠"在 UIControl 里 + 尺寸合理 + 带透明通道"打分。
- (UIView *)findCarViewForStage:(UIView *)stage {
    // 缓存优先：一旦认准了就一直用它。原车被我们藏起来后 hidden=YES 会让扫描跳过它，
    // 重新扫就可能认错视图，位置会跳。
    UIView *cached = self.carView;
    if (cached && cached.superview && cached.window) return cached;

    UIWindow *win = [self appMainWindow];
    if (!win || !win.rootViewController) return nil;
    UIView *root = win.rootViewController.view;
    CGFloat screenArea = win.bounds.size.width * win.bounds.size.height;
    if (screenArea < 1) return nil;

    UIView *best = nil;
    CGFloat bestScore = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != stage && v != self.vehicleView && ![v isKindOfClass:[UIWindow class]]) {
            UIImage *im = nil;
            if ([v isKindOfClass:[UIImageView class]]) im = ((UIImageView *)v).image;
            BOOL has = (im != nil) || (v.layer.contents != nil);
            if (has && !v.hidden && v.alpha > 0.05) {
                CGSize b = v.bounds.size;
                CGFloat area = b.width * b.height;
                if (b.width >= 60.0 && b.height >= 50.0 &&
                    area >= screenArea * 0.03 && area <= screenArea * 0.60) {
                    CGFloat score = 1.0 + area / screenArea;
                    // 在可点击控件里 => 极可能就是"爱车"
                    for (UIView *p = v.superview; p && p != root; p = p.superview) {
                        if ([p isKindOfClass:[UIControl class]]) { score += 100.0; break; }
                    }
                    // 与舞台同尺寸 => 也是候选（旧结构）
                    if (stage) {
                        CGSize s = stage.bounds.size;
                        if (fabs(b.width - s.width) < 8.0 && fabs(b.height - s.height) < 8.0) score += 20.0;
                    }
                    // 带透明通道（车是抠图）=> 加分
                    if (im) {
                        CGRect nb = NBAlphaNormalizedBounds(im);
                        if (!CGRectIsEmpty(nb) &&
                            (nb.size.width < 0.96 || nb.size.height < 0.96)) score += 40.0;
                    }
                    if (score > bestScore) { bestScore = score; best = v; }
                }
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    // 分数太低说明只是普通配图（横幅/缩略图），不能当成车去藏
    if (bestScore < 15.0) return nil;
    return best;
}

// 把用户选的车辆图贴到「原车按钮的 superview 最上层」，并藏掉原车图本身。
// 为什么加在最上层（addSubview）而不是 insertSubview:aboveSubview:：
//   原车按钮所在的父视图里还有 QGVAPWrapView 等更靠后的兄弟视图，
//   只插到紧邻上层会被它们盖住 —— 这正是之前"贴了却看不见"的原因。
//   而微调框一直是用 addSubview 挂同一个父视图的，实测看得见，所以照它来。
- (void)applyVehicleOverlay:(UIImage *)veh toCarView:(UIView *)v {
    if (!v || !v.superview || !veh) return;

    if (!self.vehicleView) {
        UIImageView *vv = [UIImageView new];
        vv.backgroundColor = [UIColor clearColor];
        vv.userInteractionEnabled = NO;                    // 点击穿透 -> 爱车按钮照常响应
        vv.contentMode = UIViewContentModeScaleAspectFit;   // 等比缩放，绝不拉伸
        vv.clipsToBounds = NO;
        self.vehicleView = vv;
    }

    if (!self.carStateSaved) {
        self.carStateSaved = YES;
        self.carWasHidden = v.hidden;
        self.carWasAlpha = v.alpha;
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *im = ((UIImageView *)v).image;
            if (im) self.originalCarImage = im;
        }
        NBLOG(@"[车视图] 认准 %@ frame=%@ bounds=%@ 原图=%@", NSStringFromClass([v class]),
              NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
              self.originalCarImage ? NSStringFromCGSize(self.originalCarImage.size) : @"layer");
    }

    // 交给 setHidden: 拦截器保护 —— App 之后任何一次「把它设成可见」都会被当场改回隐藏
    gNBCarGuard = v;

    UIImageView *vv = self.vehicleView;
    vv.image = veh;
    vv.frame = [self vehicleFrameForCarView:v];
    vv.autoresizingMask = v.autoresizingMask;
    if (vv.superview != v.superview) {
        [vv removeFromSuperview];
        [v.superview addSubview:vv];                        // 最上层
    } else {
        [v.superview bringSubviewToFront:vv];
    }
    v.hidden = YES;                                         // 藏原车（按钮本身仍可点）

    NBLOG(@"[车视图] 贴图层 %@ 于 %@ (super=%@) 原车hidden=%d",
          NSStringFromCGRect(vv.frame), NSStringFromCGSize(veh.size),
          NSStringFromClass([v.superview class]), (int)v.hidden);
}

- (void)restoreCarViews {
    UIView *v = self.carView;
    [self.vehicleView removeFromSuperview];
    self.vehicleView = nil;
    // 先撤掉拦截再还原 hidden，否则设回 NO 会被自己打回 YES
    gNBCarGuard = nil;
    if (v && self.carStateSaved) {
        v.hidden = self.carWasHidden;
        v.alpha = self.carWasAlpha;
    }
    self.carStateSaved = NO;
    self.originalCarImage = nil;
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
    self.bgStamp = nil;
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win) return;
    // 舞台图找不到也不影响换车（比如停在别的页面），只有背景依赖它
    UIImageView *stage = [self findStageImageView];
    if (stage) self.stageView = stage;

    NSString *bgPath = [self storedPathForSlot:@"bg"];
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *bgImg = bgPath ? [UIImage imageWithContentsOfFile:bgPath] : nil;
    UIImage *vehImg = vehPath ? [UIImage imageWithContentsOfFile:vehPath] : nil;

    // 1) 找原车视图（定位 + 当挂载点）
    UIView *car = [self findCarViewForStage:stage];
    if (car) self.carView = car;
    if (car) {
        CGRect inStage = stage ? [stage convertRect:car.bounds fromView:car] : car.frame;
        NBLOG(@"[车视图] %@ frame=%@ -> stage %@", NSStringFromClass([car class]),
              NSStringFromCGRect(car.frame), NSStringFromCGRect(inStage));
    } else if (!self.vehicleView) {
        NBLOG(@"[车视图] 没找到");
    }

    // 2) 捕获原舞台图
    if (stage && !self.originalStageImage && stage.image && stage.image != self.stageImage) {
        self.originalStageImage = stage.image;
        self.originalStageContentMode = stage.contentMode;
        self.contentModeCaptured = YES;
        NBLOG(@"[舞台] 捕获原图 %@ mode=%ld",
              NSStringFromCGSize(stage.image.size), (long)stage.contentMode);
    }

    // 3) 背景 —— 改写舞台图自己的 image（一直有效的那条路）
    //    判断依据是「文件指纹 + image 还是不是我上次设的那张」，
    //    只看指针会漏掉「同一个文件名换了内容」的情况。
    if (stage && bgImg) {
        NSString *stamp = [self stampForPath:bgPath];
        BOOL same = (self.stageImage != nil) && (stage.image == self.stageImage) &&
                    (stamp != nil) && (self.bgStamp != nil) && [self.bgStamp isEqualToString:stamp];
        if (!same) {
            UIImage *img = [self renderStageImage:stage.bounds.size bg:bgImg];
            if (img) {
                self.stageImage = img;
                self.bgStamp = stamp;
                stage.image = img;
                // 保持 App 自己的 contentMode：下拉怎么动就怎么动，不额外放大
                if (self.contentModeCaptured) stage.contentMode = self.originalStageContentMode;
            }
        }
    } else if (!bgImg && self.stageImage) {
        [self restoreStage];
    }

    // 4) 车辆 —— 贴在原车按钮最上层 + 藏原车（微调框验证过这条渲染路径）
    if (vehImg && car) {
        [self applyVehicleOverlay:vehImg toCarView:car];
    } else if (!vehImg && self.vehicleView) {
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
// 微调对象就是「我们贴的那个车辆图层」本身 —— 所见即所得；
// 存的是「相对原车视图 frame 的比例」，所以 App 换布局/换尺寸后位置也不会跑。

- (void)beginAdjust:(NSString *)target {
    (void)target;
    UIImageView *stage = [self findStageImageView];
    if (!stage) { [self alertDone:@"没找到车辆区域，请回到车控页再试"]; return; }
    if (![self storedPathForSlot:@"veh"]) { [self alertDone:@"还没有替换车辆图片"]; return; }

    self.stageView = stage;
    UIView *car = self.carView;
    if (!car || !car.superview) car = [self findCarViewForStage:stage];
    if (!car || !car.superview) { [self alertDone:@"没找到原车图层，点「调试：查车视图」看看"]; return; }
    self.carView = car;
    [self applyOverlays];                                   // 保证图层在位

    UIImageView *vv = self.vehicleView;
    if (!vv) { [self alertDone:@"车辆图层没挂上，点「调试：导出视图树」看看"]; return; }

    if (!self.adjustPan) {
        self.adjustPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPanned:)];
        self.adjustPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(adjustPinched:)];
    }
    if (self.adjustPan.view) [self.adjustPan.view removeGestureRecognizer:self.adjustPan];
    if (self.adjustPinch.view) [self.adjustPinch.view removeGestureRecognizer:self.adjustPinch];
    [vv addGestureRecognizer:self.adjustPan];
    [vv addGestureRecognizer:self.adjustPinch];

    vv.userInteractionEnabled = YES;                        // 微调期间自己收手势
    vv.layer.borderWidth = 1.5;
    vv.layer.borderColor = [UIColor systemBlueColor].CGColor;
    self.adjusting = YES;
    [self.ballButton setTitle:@"✓" forState:UIControlStateNormal];
    [self unhideBall];
    NBLOG(@"[微调] 进入 frame=%@ host=%@ norm=%@", NSStringFromCGRect(vv.frame),
          NSStringFromClass([car.superview class]), NSStringFromCGRect([self vehicleNormRect]));
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
    UIView *car = self.carView;
    UIImageView *vv = self.vehicleView;
    if (vv && car) {
        CGSize bs = car.bounds.size;
        if (bs.width > 1 && bs.height > 1) {
            CGRect f = vv.frame;
            NSString *rect = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                              (f.origin.x - car.frame.origin.x) / bs.width,
                              (f.origin.y - car.frame.origin.y) / bs.height,
                              f.size.width / bs.width, f.size.height / bs.height];
            [[NSUserDefaults standardUserDefaults] setObject:rect forKey:kKeyVehRect];
            NBLOG(@"[微调] 保存 norm=%@", rect);
        }
    }
    if (vv) {
        vv.layer.borderWidth = 0.0;
        [vv removeGestureRecognizer:self.adjustPan];
        [vv removeGestureRecognizer:self.adjustPinch];
        vv.userInteractionEnabled = NO;                      // 恢复点击穿透
    }
    self.adjusting = NO;
    [self.ballButton setTitle:@"🛴" forState:UIControlStateNormal];
    [self applyOverlays];
    [self scheduleReapply];
    [self alertDone:@"车辆图位置已保存"];
}

- (void)resetVehicleRect {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
    [self applyOverlays];
    [self scheduleReapply];
    [self alertDone:@"车辆图已对准原车位置（正好盖住原车）"];
}

#pragma mark - 恢复

- (void)restoreVehicle {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehPath];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
    [self applyOverlays];                    // veh 路径没了 -> applyOverlays 里会还原车图
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
    UIView *car = self.carView ?: [self findCarViewForStage:stage];
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"舞台 %@ %@\n原车视图 %@ frame=%@\n我们的图层 %@ %@ img=%@",
     stage ? NSStringFromClass([stage class]) : @"nil",
     stage ? NSStringFromCGRect(stage.bounds) : @"-",
     car ? NSStringFromClass([car class]) : @"nil",
     car ? NSStringFromCGRect(car.frame) : @"-",
     self.vehicleView ? NSStringFromClass([self.vehicleView class]) : @"nil",
     self.vehicleView ? NSStringFromCGRect(self.vehicleView.frame) : @"-",
     self.vehicleView.image ? NSStringFromCGSize(self.vehicleView.image.size) : @"nil"];
    if (car) {
        UIImage *im = [car isKindOfClass:[UIImageView class]] ? ((UIImageView *)car).image : nil;
        [m appendFormat:@"\n原车 img=%@ hidden=%d", im ? NSStringFromCGSize(im.size) : @"layer", (int)car.hidden];
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
        [out appendFormat:@"[stage] %@ frame=%@ img=%@ (ours=%d)\n",
         stageCls, stageFrame, stageImg, (int)isOurs];
        UIView *car = self.carView;
        if (car) {
            [out appendFormat:@"[carview] %@ frame=%@ hidden=%d super=%@\n",
             NSStringFromClass([car class]), NSStringFromCGRect(car.frame), (int)car.hidden,
             NSStringFromClass([car.superview class])];
        }
        if (self.vehicleView) {
            [out appendFormat:@"[ours] %@ frame=%@ img=%@ norm=%@\n",
             NSStringFromClass([self.vehicleView class]), NSStringFromCGRect(self.vehicleView.frame),
             self.vehicleView.image ? NSStringFromCGSize(self.vehicleView.image.size) : @"nil",
             NSStringFromCGRect([self vehicleNormRect])];
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
     (view == self.vehicleView ? @"<OUR-VEHICLE>" : @"")];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end
