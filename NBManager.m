#import "NBManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <math.h>
#import <stdlib.h>

// 视频/媒体一律走 objc_getClass 运行时取类 + 字符串字面量常量，
// 不链接 AVFoundation/CoreMedia：dylib 的 LC_LOAD_DYLIB 集合与 v0.1.15 完全一致，
// 避免个别设备/引导环境下 framework 解析失败导致整个 tweak 静默拒载。

// kCMTimeZero 等价物（不引用 CoreMedia 符号；flags=1 即 kCMTimeFlags_Valid）
static CMTime NBCMZero(void) {
    CMTime t;
    t.value = 0;
    t.timescale = 1;
    t.flags = 1;
    t.epoch = 0;
    return t;
}

// 带一个对象参数的消息发送（绕开 Theos SDK 缺失的类工厂方法声明）
static id NBMsgSend1(id rcv, SEL sel, id arg) {
    return ((id (*)(id, SEL, id))objc_msgSend)(rcv, sel, arg);
}

// ============================================================
// NinebotSkin v0.2.0 —— 九号出行 车辆图/背景图替换（图片 + 背景视频）
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
static NSString * const kKeyBgRect    = @"nbskin_bg_rect";  // 背景绘制区域（相对舞台）
static NSString * const kKeyBgMode    = @"nbskin_bg_mode";  // 0=整个上半屏 1=车控区域
static NSString * const kKeyBgSrcPath = @"nbskin_bg_src";   // 裁剪前的原图（再次裁剪用）
static NSString * const kKeyBgVideoPath = @"nbskin_bg_video_path"; // 背景视频（循环静音播放）
static NSString * const kKeyBgVideoRect = @"nbskin_bg_video_rect"; // 视频画面裁剪框（归一化 0..1，NSStringFromCGRect）

// 「车控区域」的上边界（相对舞台高度）。
// 舞台高 441.47；cell 内容区从 y=103 起（「车控」标题那一行）→ 103 / 441.47 ≈ 0.2333
static CGFloat const kBgRegionTop = 0.2333;

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

// 把任意方向的图「正立化」成 scale=1 的位图，这样像素坐标 == pt 坐标，裁剪才好算
static UIImage *NBNormalizedImage(UIImage *img) {
    if (!img) return nil;
    CGSize s = img.size;
    if (s.width < 1 || s.height < 1) return nil;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1.0;
    f.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, s.width, s.height)];
    }];
}

// 等比缩到最长边不超过 maxSide（用于把"重新裁剪用的原图"压小，别存 4000px 的 PNG）
static UIImage *NBScaleImage(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGSize s = img.size;
    CGFloat m = MAX(s.width, s.height);
    if (m <= maxSide || m < 1.0) return img;
    CGFloat k = maxSide / m;
    CGSize n = CGSizeMake(floor(s.width * k), floor(s.height * k));
    if (n.width < 1 || n.height < 1) return img;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1.0;
    f.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:n format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, n.width, n.height)];
    }];
}

// 编码 JPEG（比 PNG 快得多，体积也小得多）
static NSData *NBEncodeJPEG(UIImage *img, CGFloat quality) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (!dst) return nil;
    NSDictionary *opt = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)};
    CGImageDestinationAddImage(dst, cg, (__bridge CFDictionaryRef)opt);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? out : nil;
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

// ---------- 背景裁剪页 ----------
// 固定裁剪框 + 可拖动/双指缩放的图片（UIScrollView 的标准做法）。
// 框的宽高比 = 当前显示方式的目标区域比例，所以裁完铺进去正好，不会再被二次裁掉。
@interface NBCropViewController : UIViewController <UIScrollViewDelegate> {
    UIImage *_source;
    CGFloat _aspect;
    UIScrollView *_scroll;
    UIImageView *_iv;
    CGSize _cropSize;
    CGFloat _baseScale;
    BOOL _centered;
}
@property (strong, nonatomic) UIImage *sourceImage;   // 裁剪前的原图
@property (copy, nonatomic) void (^onFinish)(UIImage *img);
@property (copy, nonatomic) void (^onCancel)(void);
// 视频模式：不裁像素，只回报归一化裁剪框（相对整张画面 0..1）；非 nil 时 tapDone 走 rect 分支
@property (copy, nonatomic) void (^onFinishRect)(CGRect rect);
@property (copy, nonatomic) NSString *cropTitle;      // 顶部标题（默认「裁剪背景图」）
- (instancetype)initWithImage:(UIImage *)img aspect:(CGFloat)aspect;
@end

@implementation NBCropViewController

- (instancetype)initWithImage:(UIImage *)img aspect:(CGFloat)aspect {
    self = [super init];
    if (self) {
        _source = img;
        _aspect = (aspect > 0.05) ? aspect : 1.0;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UILabel *)nbLabel:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [UILabel new];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    [l sizeToFit];
    return l;
}

- (UIButton *)nbButton:(NSString *)title size:(CGFloat)size bold:(BOOL)bold {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    [b sizeToFit];
    CGRect f = b.frame;
    f.size.width = MAX(f.size.width, 64.0);
    f.size.height = MAX(f.size.height, 44.0);
    b.frame = f;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    CGSize vb = self.view.bounds.size;
    CGFloat topBar = 92.0, bottomBar = 96.0;

    // ---- 裁剪框尺寸：先按可用宽度，太高就按可用高度反算 ----
    CGFloat availW = vb.width - 24.0;
    CGFloat availH = vb.height - topBar - bottomBar;
    CGFloat w = availW, h = w / _aspect;
    if (h > availH) { h = availH; w = h * _aspect; }
    _cropSize = CGSizeMake(floor(w), floor(h));
    CGRect cropFrame = CGRectMake(floor((vb.width - _cropSize.width) / 2.0),
                                  floor(topBar + (availH - _cropSize.height) / 2.0),
                                  _cropSize.width, _cropSize.height);

    // ---- 图片 ----
    CGSize is = _source.size;
    if (is.width < 1 || is.height < 1) is = CGSizeMake(1, 1);
    _baseScale = MAX(_cropSize.width / is.width, _cropSize.height / is.height);

    _scroll = [[UIScrollView alloc] initWithFrame:cropFrame];
    _scroll.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.bouncesZoom = YES;
    _scroll.decelerationRate = UIScrollViewDecelerationRateFast;
    _scroll.delegate = self;
    _scroll.clipsToBounds = YES;
    // 不让安全区自动改 contentInset，否则 contentOffset 会偏，裁出来的位置会歪
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scroll];

    _iv = [[UIImageView alloc] initWithImage:_source];
    _iv.frame = CGRectMake(0, 0, is.width * _baseScale, is.height * _baseScale);
    _iv.contentMode = UIViewContentModeScaleToFill;   // frame 已按原比例算好
    [_scroll addSubview:_iv];
    _scroll.contentSize = _iv.frame.size;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 5.0;

    // ---- 框外遮暗 ----
    UIColor *mask = [UIColor colorWithWhite:0.0 alpha:0.72];
    UIView *maskTop = [[UIView alloc] initWithFrame:CGRectMake(0, 0, vb.width, cropFrame.origin.y)];
    UIView *maskBottom = [[UIView alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(cropFrame),
                                                                 vb.width, vb.height - CGRectGetMaxY(cropFrame))];
    UIView *maskLeft = [[UIView alloc] initWithFrame:CGRectMake(0, cropFrame.origin.y,
                                                               cropFrame.origin.x, cropFrame.size.height)];
    UIView *maskRight = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMaxX(cropFrame), cropFrame.origin.y,
                                                                vb.width - CGRectGetMaxX(cropFrame), cropFrame.size.height)];
    NSArray<UIView *> *masks = @[maskTop, maskBottom, maskLeft, maskRight];
    for (UIView *mv in masks) {
        mv.backgroundColor = mask;
        mv.userInteractionEnabled = NO;
        [self.view addSubview:mv];
    }
    // 画个白框，让边界清楚
    UIView *border = [[UIView alloc] initWithFrame:cropFrame];
    border.layer.borderWidth = 1.0;
    border.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    border.userInteractionEnabled = NO;
    [self.view addSubview:border];

    // ---- 顶部按钮 ----
    UIButton *cancel = [self nbButton:@"取消" size:17.0 bold:NO];
    cancel.frame = CGRectMake(12.0, 46.0, cancel.frame.size.width, 44.0);
    [cancel addTarget:self action:@selector(tapCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    UIButton *done = [self nbButton:@"完成" size:17.0 bold:YES];
    done.frame = CGRectMake(vb.width - done.frame.size.width - 12.0, 46.0, done.frame.size.width, 44.0);
    [done addTarget:self action:@selector(tapDone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    UILabel *title = [self nbLabel:_cropTitle.length ? _cropTitle : @"裁剪背景图" size:17.0 bold:YES];
    title.center = CGPointMake(vb.width / 2.0, 68.0);
    [self.view addSubview:title];

    // ---- 底部提示 + 重置 ----
    UILabel *hint = [self nbLabel:@"拖动移动 · 双指缩放" size:13.0 bold:NO];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    hint.center = CGPointMake(vb.width / 2.0, CGRectGetMaxY(cropFrame) + 28.0);
    [self.view addSubview:hint];

    UIButton *reset = [self nbButton:@"重置" size:15.0 bold:NO];
    reset.center = CGPointMake(vb.width / 2.0, CGRectGetMaxY(cropFrame) + 66.0);
    [reset addTarget:self action:@selector(tapReset) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:reset];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_centered || !_scroll) return;
    _centered = YES;
    [self centerImage];
}

- (void)centerImage {
    if (!_scroll || !_iv) return;
    _scroll.zoomScale = 1.0;
    CGSize cs = _scroll.contentSize;
    CGFloat ox = MAX(0.0, (cs.width - _cropSize.width) / 2.0);
    CGFloat oy = MAX(0.0, (cs.height - _cropSize.height) / 2.0);
    _scroll.contentOffset = CGPointMake(ox, oy);
}

- (void)tapReset {
    [self centerImage];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv {
    return _iv;
}

- (void)tapCancel {
    if (self.onCancel) self.onCancel();
}

- (void)tapDone {
    // 视频模式：只回报归一化裁剪框，不产出图片
    if (self.onFinishRect) {
        CGRect r = [self normalizedCropRect];
        if (CGRectIsNull(r)) r = CGRectMake(0.0, 0.0, 1.0, 1.0);
        self.onFinishRect(r);
        return;
    }
    UIImage *out = [self croppedImage];
    if (!out) {
        // 裁不出来就把原图交回去，别让用户卡在这一页
        out = NBNormalizedImage(_source);
    }
    if (self.onFinish) self.onFinish(out);
}

// 当前裁剪框相对整张画面的归一化 rect（0..1）。取不到时返回 CGRectNull
- (CGRect)normalizedCropRect {
    if (!_scroll || !_iv) return CGRectNull;
    CGFloat s = _baseScale * _scroll.zoomScale;
    if (s <= 0.0001) return CGRectNull;
    CGPoint o = _scroll.contentOffset;
    CGRect r = CGRectMake(o.x / s, o.y / s, _cropSize.width / s, _cropSize.height / s);
    UIImage *flat = NBNormalizedImage(_source);
    if (!flat) return CGRectNull;
    CGSize fs = flat.size;
    if (fs.width < 1.0 || fs.height < 1.0) return CGRectNull;
    r = CGRectIntersection(r, CGRectMake(0.0, 0.0, fs.width, fs.height));
    if (CGRectIsNull(r) || r.size.width < 1.0 || r.size.height < 1.0) return CGRectNull;
    return CGRectMake(r.origin.x / fs.width, r.origin.y / fs.height,
                      r.size.width / fs.width, r.size.height / fs.height);
}

- (UIImage *)croppedImage {
    if (!_scroll || !_iv) return nil;
    CGFloat s = _baseScale * _scroll.zoomScale;      // 原图 pt -> 内容 pt
    if (s <= 0.0001) return nil;
    CGPoint o = _scroll.contentOffset;
    CGRect r = CGRectMake(o.x / s, o.y / s, _cropSize.width / s, _cropSize.height / s);

    UIImage *flat = NBNormalizedImage(_source);      // 正立、scale=1 -> 像素坐标
    if (!flat) return nil;
    CGSize fs = flat.size;
    r = CGRectIntersection(r, CGRectMake(0, 0, fs.width, fs.height));
    if (CGRectIsNull(r) || r.size.width < 1.0 || r.size.height < 1.0) return nil;
    CGImageRef cg = CGImageCreateWithImageInRect(flat.CGImage, r);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    NBLOG(@"[裁剪] 源 %@ -> 取 %@ -> %@", NSStringFromCGSize(fs), NSStringFromCGRect(r),
          NSStringFromCGSize(out.size));
    return out;
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
@property (copy,   nonatomic) NSString *bgStamp;             // 渲染这张背景时用的文件指纹
@property (assign, nonatomic) BOOL pendingStageRestore;      // 点了"恢复背景"但当时不在车控页
@property (strong, nonatomic) UIImage *cachedBgImage;         // 背景解码缓存（避免每次 apply 都读盘解码）
@property (copy,   nonatomic) NSString *cachedBgPath;

// 背景视频（无限循环、静音，挂在舞台图层之上、车按钮之下）
// 循环用 AVPlayerItemDidPlayToEndTime 通知 seek 回开头 —— 不依赖 AVPlayerLooper
@property (strong, nonatomic) AVPlayer *bgPlayer;
@property (strong, nonatomic) AVPlayerLayer *bgLayer;
@property (copy,   nonatomic) NSString *bgVideoPath;

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
    // 微调入口已移除：任何历史遗留的车辆偏移都没用了，
    // 一律回到「正好盖住原车」的默认位置，避免升级后车图被旧偏移带歪
    if ([[NSUserDefaults standardUserDefaults] stringForKey:kKeyVehRect]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
        NBLOG(@"[启动] 已清除历史车辆偏移，车辆图回到对准原车的位置");
    }
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
    // 有"待还原"时，即使已经没有替换内容也要继续跑，否则背景会一直卡在合成图上
    if (self.pendingStageRestore) {
        UIImageView *s = self.stageView ?: [self findStageImageView];
        if (s) {
            NBLOG(@"[看门狗] 发现待还原的背景，补做");
            [self applyOverlays];
            return;
        }
    }
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

    // 背景视频：层被摘了就重挂；播到结尾就 seek 回开头重播（通知兜底 + 时间检查双保险）
    if (self.bgLayer) {
        UIImageView *sv = self.stageView;
        if (sv && sv.superview) {
            if (self.bgLayer.superlayer != sv.superview.layer) {
                NBLOG(@"[看门狗] 视频层掉了，重挂");
                [self applyVideoLayer];
            } else if ([self bgVideoAtEnd]) {
                NBLOG(@"[看门狗] 视频播到结尾，重播");
                [self restartBgVideo];
            } else if (self.bgPlayer.rate == 0.0) {
                [self.bgPlayer play];
            }
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
    if (self.adjusting) { [self finishAdjust]; return; }
    UIViewController *top = [self topVC];
    if (!top) { NBLOG(@"[菜单] 找不到可用顶层 VC"); return; }
    self.ballWindow.hidden = YES;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"九号换装"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak NBManager *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【车辆图片】" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf pickImageFor:@"veh"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"替换【背景图片】（选图后可裁剪）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf pickImageFor:@"bg"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新裁剪背景图" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf recropBackground]; }]];    [ac addAction:[UIAlertAction actionWithTitle:@"替换【背景视频】（循环播放 · 静音）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf pickVideoFor:@"bgvideo"]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新裁剪视频画面" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf recropBgVideo]; }]];
    NSString *modeName = ([self bgMode] == 0) ? @"整个上半屏" : @"车控区域";
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"背景显示方式（%@）", modeName]
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf chooseBgMode]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"一键恢复（车辆+背景）" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action){ [weakSelf oneKeyRestore]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"调试：导出视图树" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){ [weakSelf dumpViewTree]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *action){ [weakSelf unhideBall]; }]];

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

// 背景图解码缓存：同一个路径只解码一次。
// 换背景走 commitBackgroundImage 时会直接把内存里那张塞进缓存，所以是零解码、零等待。
- (UIImage *)bgImageForPath:(NSString *)p {
    if (!p.length) return nil;
    if (self.cachedBgImage && self.cachedBgPath && [self.cachedBgPath isEqualToString:p]) {
        return self.cachedBgImage;
    }
    UIImage *img = [UIImage imageWithContentsOfFile:p];
    if (img) {
        self.cachedBgImage = img;
        self.cachedBgPath = p;
    }
    return img;
}

- (BOOL)hasAnyReplacement {
    return [self hasBgVideo] ||
           [self storedPathForSlot:@"bg"] != nil ||
           [self storedPathForSlot:@"veh"] != nil;
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
- (NSInteger)bgMode {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kKeyBgMode];
}

// 背景要铺在舞台的哪块区域。
// 模式 0：整张舞台图（0 ~ 441.47），也就是"上半部分全部显示"
// 模式 1："车控区域"——从「车控」标题那一行（舞台 y≈0.233）一直到底。
//         上面状态栏/消息卡片那一段保持 App 原样，不会被背景染色。
- (CGRect)bgRegionInSize:(CGSize)sz {
    if ([self bgMode] == 0) return CGRectMake(0, 0, sz.width, sz.height);
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgRect];
    CGRect n;
    if (raw.length) n = NBParseNormalizedRect(raw);
    else n = CGRectMake(0, kBgRegionTop, 1, 1.0 - kBgRegionTop);
    if (n.size.width <= 0.02 || n.size.height <= 0.02)
        n = CGRectMake(0, kBgRegionTop, 1, 1.0 - kBgRegionTop);
    return CGRectMake(n.origin.x * sz.width, n.origin.y * sz.height,
                      n.size.width * sz.width, n.size.height * sz.height);
}

- (UIImage *)renderStageImage:(CGSize)sz bg:(UIImage *)bg {
    if (sz.width < 1 || sz.height < 1 || !bg) return nil;
    CGRect full = CGRectMake(0, 0, sz.width, sz.height);
    CGRect region = [self bgRegionInSize:sz];
    BOOL whole = (CGRectGetMinX(region) <= 0.5 && CGRectGetMinY(region) <= 0.5 &&
                  fabs(CGRectGetWidth(region) - sz.width) < 0.5 &&
                  fabs(CGRectGetHeight(region) - sz.height) < 0.5);
    UIImage *orig = self.originalStageImage;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 3.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor whiteColor] setFill];
        CGContextFillRect(c, full);
        // 只铺一块时，区域外要保留原舞台图的样子，
        // 否则上面会多出一条纯色带（原图是渐变时特别明显）
        if (!whole && orig) NBDrawImage(c, orig, full, YES);
        NBDrawImage(c, bg, region, YES);
    }];
    NBLOG(@"[合成] 舞台 %@ 背景 %@ 模式%ld 区域 %@", NSStringFromCGSize(sz), NSStringFromCGSize(bg.size),
          (long)[self bgMode], NSStringFromCGRect(region));
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
    if (!stage) {
        // 不在车控页（舞台图根本没挂出来）-> 别清状态，等回到车控页再还
        NBLOG(@"[舞台] 暂时找不到舞台图，待还原（回车控页自动完成）");
        self.pendingStageRestore = YES;
        return;
    }
    if (self.stageImage && stage.image == self.stageImage) {
        if (self.originalStageImage) stage.image = self.originalStageImage;
        if (self.contentModeCaptured) stage.contentMode = self.originalStageContentMode;
        NBLOG(@"[舞台] 已还原原图");
    } else if (self.stageImage) {
        NBLOG(@"[舞台] 舞台图已被 App 换掉，不用我还");
    }
    self.stageImage = nil;
    self.bgStamp = nil;
    self.pendingStageRestore = NO;
}

- (void)applyOverlays {
    UIWindow *win = [self appMainWindow];
    if (!win) return;
    // 舞台图找不到也不影响换车（比如停在别的页面），只有背景依赖它。
    // 已有的那个还在 window 上就直接用，别每次都遍历整棵视图树（换背景时这点很关键）。
    UIImageView *stage = self.stageView;
    if (!stage || !stage.window) stage = [self findStageImageView];
    if (stage) self.stageView = stage;

    NSString *bgPath = [self storedPathForSlot:@"bg"];
    NSString *vehPath = [self storedPathForSlot:@"veh"];
    UIImage *bgImg = [self bgImageForPath:bgPath];
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
        NSString *stamp = [self currentBgStampForPath:bgPath];
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
    } else if (!bgImg && (self.stageImage || self.pendingStageRestore)) {
        [self restoreStage];
    }

    // 4) 车辆 —— 贴在原车按钮最上层 + 藏原车（微调框验证过这条渲染路径）
    if (vehImg && car) {
        [self applyVehicleOverlay:vehImg toCarView:car];
    } else if (!vehImg && self.vehicleView) {
        [self restoreCarViews];
    }

    // 5) 背景视频（有视频就盖在背景上，循环静音）
    [self applyVideoLayer];
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
    if ([slot isEqualToString:@"bgvideo"]) { [self handleVideoResult:res]; return; }

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
        BOOL ok = NO;
        NSString *savedPath = nil;
        UIImage *bgImage = nil;

        if (isVeh) {
            NSData *png = NBPrepareVehiclePNG(data, &px, &trim, &stripped);
            if (png.length) {
                NSString *path = [NBLogDir() stringByAppendingPathComponent:@"veh.png"];
                ok = [png writeToFile:path atomically:YES];
                savedPath = path;
            }
            NBLOG(@"[选图] 车辆 原始%luB -> png%luB %.0fx%.0f 去白底=%d 裁边=%.0f%% ok=%d",
                  (unsigned long)data.length, (unsigned long)png.length,
                  px.width, px.height, (int)stripped, trim * 100.0, (int)ok);
        } else {
            // 背景：只要解码成 UIImage 就够，**不做整图 PNG 重编码**
            // （4000×3000 的图重编码一次要几百毫秒~1 秒，这就是"选完图半天才进裁剪页"的大头）
            bgImage = [UIImage imageWithData:data];
            px = bgImage.size;
            ok = (bgImage != nil);
            NBLOG(@"[选图] 背景 原始%luB 解码 %@ ok=%d",
                  (unsigned long)data.length, NSStringFromCGSize(px), (int)ok);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [self alertDone:@"图片解析失败（格式特殊），请换一张"];
                return;
            }
            if (isVeh) {
                // 换图就重置位置：永远按「正好盖住原车」对位，
                // 避免以前残留的偏移把新车图带到别处（菜单里的重置项已按用户要求去掉）
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
                [[NSUserDefaults standardUserDefaults] setObject:savedPath forKey:kKeyVehPath];
                [self applyOverlays];
                [self scheduleReapply];
                NSMutableString *note = [NSMutableString string];
                if (stripped) [note appendString:@"（已自动去掉白底）"];
                if (trim > 0.05) [note appendFormat:@"（已裁掉周围 %.0f%% 空白）", trim * 100.0];
                [note appendString:@"\n已自动对准原车位置"];
                [self alertDone:[NSString stringWithFormat:@"已替换车辆图片\n%@×%@ px%@",
                                 @((NSInteger)px.width), @((NSInteger)px.height), note]];
            } else {
                [self openCropWithImage:bgImage];
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

#pragma mark - 背景裁剪 / 显示方式

// 当前显示方式对应的目标区域宽高比（裁剪框就用这个比例，裁完正好铺满）
- (CGFloat)bgRegionAspect {
    UIImageView *stage = self.stageView ?: [self findStageImageView];
    CGSize sz = stage ? stage.bounds.size : CGSizeMake(430.0, 441.47);
    if (sz.width < 1 || sz.height < 1) sz = CGSizeMake(430.0, 441.47);
    CGRect r = [self bgRegionInSize:sz];
    if (r.size.height < 1) return sz.width / sz.height;
    return r.size.width / r.size.height;
}

// 拿着内存里的图直接开裁剪页（不再落盘读盘）
- (void)openCropWithImage:(UIImage *)src {
    if (!src) { [self alertDone:@"图片读取失败，请换一张"]; return; }
    CGFloat aspect = [self bgRegionAspect];
    __weak NBManager *weakSelf = self;
    // picker 刚 dismiss，等转场结束再 present，否则会冲突
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NBManager *me = weakSelf;
        if (!me) return;
        NBCropViewController *vc = [[NBCropViewController alloc] initWithImage:src aspect:aspect];
        vc.sourceImage = src;
        // vc 强持有 block，block 里不能再强持有 vc（会循环引用）
        __weak NBCropViewController *weakVC = vc;
        vc.onCancel = ^{
            NBCropViewController *strongVC = weakVC;
            if (strongVC) [me dismissCropVC:strongVC];
        };
        vc.onFinish = ^(UIImage *img) {
            NBCropViewController *strongVC = weakVC;
            if (strongVC) [me finishCropVC:strongVC image:img];
        };
        [me presentTracked:vc];
        NBLOG(@"[裁剪] 打开裁剪页 aspect=%.3f", aspect);
    });
}

- (void)openCropWithSourcePath:(NSString *)path {
    UIImage *src = [UIImage imageWithContentsOfFile:path];
    if (!src) { [self alertDone:@"图片读取失败，请换一张"]; return; }
    [self openCropWithImage:src];
}

- (void)dismissCropVC:(UIViewController *)vc {
    [vc dismissViewControllerAnimated:YES completion:^{ [self unhideBall]; }];
}

// 关键：**先应用背景，再关裁剪页**。
// 这样点「完成」的瞬间底下就变了，转场动画滑走时已经看到新背景，不用等 0.3s 的 dismiss 回调。
- (void)finishCropVC:(UIViewController *)vc image:(UIImage *)img {
    UIImage *src = nil;
    if ([vc isKindOfClass:[NBCropViewController class]]) src = ((NBCropViewController *)vc).sourceImage;
    BOOL ok = [self commitBackgroundImage:img silent:YES];
    if (src) [self saveBgSourceAsync:src];          // 原图后台落盘，不阻塞
    NSString *modeNote = ([self bgMode] == 0) ? @"整个上半屏" : @"车控区域";
    NSString *msg = ok ? [NSString stringWithFormat:@"背景已应用\n%@×%@ px · %@",
                          @((NSInteger)img.size.width), @((NSInteger)img.size.height), modeNote]
                       : @"裁剪结果保存失败，请换一张图";
    __weak NBManager *weakSelf = self;
    [vc dismissViewControllerAnimated:YES completion:^{
        NBManager *me = weakSelf;
        if (!me) return;
        [me unhideBall];
        [me alertDone:msg];
    }];
}

- (NSString *)currentBgStampForPath:(NSString *)p {
    NSString *st = [self stampForPath:p];
    return [NSString stringWithFormat:@"%@|%ld", st ?: @"-", (long)[self bgMode]];
}

- (BOOL)commitBackgroundImage:(UIImage *)img silent:(BOOL)silent {
    if (!img) {
        if (!silent) [self alertDone:@"裁剪失败，请换一张图"];
        return NO;
    }
    NSString *path = [NBLogDir() stringByAppendingPathComponent:@"bg.png"];

    // 顺序很重要：先把「路径 + 内存图」都布好，然后立刻重画。
    // PNG 编码和写盘都扔到后台，主线程一点都不用等 —— 点「完成」就是马上变。
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:kKeyBgPath];
    self.cachedBgPath = path;
    self.cachedBgImage = img;
    self.stageImage = nil;                 // 强制重渲染新背景
    self.bgStamp = nil;
    [self applyOverlays];
    [self scheduleReapply];

    __weak NBManager *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *png = NBEncodePNG(img.CGImage);
        BOOL ok = png.length ? [png writeToFile:path atomically:YES] : NO;
        NBLOG(@"[裁剪] 落盘 %@ %@ %luB ok=%d", NSStringFromCGSize(img.size),
              [path lastPathComponent], (unsigned long)png.length, (int)ok);
        dispatch_async(dispatch_get_main_queue(), ^{
            NBManager *me = weakSelf;
            if (!me) return;
            if (ok) {
                // 文件已换新，把指纹对齐，免得看门狗以为被改过又重画一次
                me.bgStamp = [me currentBgStampForPath:path];
            } else if (!silent) {
                [me alertDone:@"保存失败，请检查存储空间"];
            }
        });
    });
    return YES;
}

// 裁剪前的原图另存一份（供「重新裁剪」用）。
// 限到最长边 2400 再存 JPEG：够再裁一次，又不会因为 4000px 的 PNG 编码把主线程拖住。
- (void)saveBgSourceAsync:(UIImage *)src {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *small = NBScaleImage(src, 2400.0);
        NSData *jpg = NBEncodeJPEG(small, 0.95);
        if (!jpg.length) return;
        NSString *path = [NBLogDir() stringByAppendingPathComponent:@"bg_src.jpg"];
        if ([jpg writeToFile:path atomically:YES]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSUserDefaults standardUserDefaults] setObject:path forKey:kKeyBgSrcPath];
            });
            NBLOG(@"[裁剪] 原图已存 %@ %@ %luB", NSStringFromCGSize(small.size),
                  [path lastPathComponent], (unsigned long)jpg.length);
        }
    });
}

// 重新裁剪：用裁剪前的原图重来（没有再退回已应用的图）
- (void)recropBackground {
    NSString *src = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgSrcPath];
    if (!src.length || ![[NSFileManager defaultManager] fileExistsAtPath:src]) {
        src = [self storedPathForSlot:@"bg"];
    }
    if (!src.length) { [self alertDone:@"还没有背景图，先点「替换【背景图片】」"]; return; }
    [self openCropWithSourcePath:src];
}

- (void)chooseBgMode {
    UIViewController *top = [self topVC];
    if (!top) { [self unhideBall]; return; }
    NSInteger cur = [self bgMode];
    NSString *title = cur == 0 ? @"背景显示方式（当前：整个上半屏）" : @"背景显示方式（当前：车控区域）";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:@"车控区域 = 「车控 / 电量 / 续航 / ninebot / 车」那一块，上面状态栏那段保持原样"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak NBManager *weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"① 整个上半屏（铺到状态栏后面）"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a){ [weakSelf setBgMode:0]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"② 车控区域（只有车控那一块）"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a){ [weakSelf setBgMode:1]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a){ [weakSelf unhideBall]; }]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.ballButton ?: top.view;
        ac.popoverPresentationController.sourceRect = (self.ballButton ?: top.view).bounds;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)setBgMode:(NSInteger)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kKeyBgMode];
    self.stageImage = nil;
    self.bgStamp = nil;
    [self applyOverlays];
    [self scheduleReapply];
    NBLOG(@"[背景] 显示方式 -> %ld", (long)mode);
    NSString *msg = (mode == 0)
        ? @"已改为：整个上半屏\n背景会铺到状态栏后面那一整块。\n由于比例变了，建议点「重新裁剪背景图」重新取景。"
        : @"已改为：车控区域\n只铺「车控」到底这一块，上面保持原样。\n由于比例变了，建议点「重新裁剪背景图」重新取景。";
    [self alertDone:msg];
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

#pragma mark - 背景视频
// 一段静音循环的视频铺在背景上：
//   · 层级：舞台图层 < 视频层 < 车按钮容器（车、水印照常画在上面）
//   · frame 跟随「背景显示方式」：整个上半屏 = 舞台全幅；车控区域 = 只铺那一块
//   · AVPlayerLooper 无限循环，muted 静音，不占音频会话
- (BOOL)hasBgVideo {
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgVideoPath];
    return p.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:p];
}

- (void)teardownVideoLayer {
    if (self.bgPlayer) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"AVPlayerItemDidPlayToEndTime"
                                                      object:self.bgPlayer.currentItem];
        [self.bgPlayer pause];
    }
    if (self.bgLayer) [self.bgLayer removeFromSuperlayer];
    self.bgPlayer = nil;
    self.bgLayer = nil;
    self.bgVideoPath = nil;
}

// 视频画面裁剪框（归一化 0..1）。没存或等于全画面时返回 CGRectNull
- (CGRect)videoCropRect {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgVideoRect];
    if (!s.length) return CGRectNull;
    CGRect r = CGRectFromString(s);
    if (r.size.width <= 0.001 || r.size.height <= 0.001) return CGRectNull;
    if (r.origin.x <= 0.0001 && r.origin.y <= 0.0001 &&
        r.size.width >= 0.999 && r.size.height >= 0.999) return CGRectNull;
    return r;
}

- (void)applyVideoLayer {
    UIImageView *stage = self.stageView;
    if (!stage || !stage.superview || ![self hasBgVideo]) {
        [self teardownVideoLayer];
        return;
    }
    NSString *vpath = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgVideoPath];
    if (!self.bgPlayer || ![self.bgVideoPath isEqualToString:vpath]) {
        [self teardownVideoLayer];
        Class playerItemCls = objc_getClass("AVPlayerItem");
        Class playerCls = objc_getClass("AVPlayer");
        Class playerLayerCls = objc_getClass("AVPlayerLayer");
        if (!playerItemCls || !playerCls || !playerLayerCls) {
            NBLOG(@"[视频] AVFoundation 类不可用，跳过");
            return;
        }
        AVPlayerItem *item = [(id)playerItemCls playerItemWithURL:[NSURL fileURLWithPath:vpath]];
        AVPlayer *p = [(id)playerCls playerWithPlayerItem:item];
        p.muted = YES;
        self.bgPlayer = p;
        self.bgLayer = [(id)playerLayerCls playerLayerWithPlayer:p];
        self.bgVideoPath = vpath;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(bgVideoDidEnd)
                                                     name:@"AVPlayerItemDidPlayToEndTime"
                                                   object:item];
        NBLOG(@"[视频] 建立 player %@", vpath);
    }
    if (self.bgLayer.superlayer != stage.superview.layer) {
        [stage.superview.layer insertSublayer:self.bgLayer above:stage.layer];
    }
    CGRect region = [self bgRegionInSize:stage.bounds.size];
    CGRect inSuper = [stage convertRect:region toView:stage.superview];
    if (!CGRectEqualToRect(self.bgLayer.frame, inSuper)) self.bgLayer.frame = inSuper;

    // 裁剪画面：把视频里选中的那块（归一化 rect）映射满整个区域。
    // 裁剪框比例 = 区域比例，所以用 resize + transform 不会拉伸。
    // 没裁剪时保持 aspectFill 原样（兼容老行为）。
    CGRect crop = [self videoCropRect];
    if (!CGRectIsNull(crop)) {
        self.bgLayer.videoGravity = (NSString *)@"resize";
        CGFloat W = inSuper.size.width, H = inSuper.size.height;
        if (W > 1.0 && H > 1.0) {
            CATransform3D t3 = CATransform3DMakeScale(1.0 / crop.size.width, 1.0 / crop.size.height, 1.0);
            t3 = CATransform3DTranslate(t3,
                                        -(crop.origin.x * W) / crop.size.width,
                                        -(crop.origin.y * H) / crop.size.height, 0);
            if (!CATransform3DEqualToTransform(self.bgLayer.transform, t3)) self.bgLayer.transform = t3;
        }
    } else {
        self.bgLayer.videoGravity = (NSString *)@"AVLayerVideoGravityResizeAspectFill";
        if (!CATransform3DIsIdentity(self.bgLayer.transform)) self.bgLayer.transform = CATransform3DIdentity;
    }
    if (self.bgPlayer.rate == 0.0) [self.bgPlayer play];
}

// 是否已播到结尾（duration 无效时返回 NO，不误判）
- (BOOL)bgVideoAtEnd {
    AVPlayer *p = self.bgPlayer;
    if (!p || !p.currentItem) return NO;
    CMTime cur = p.currentTime;
    CMTime dur = p.currentItem.duration;
    if (!((dur.flags & 1) && dur.timescale > 0 && cur.timescale > 0)) return NO;
    double cs = (double)cur.value / (double)cur.timescale;
    double ds = (double)dur.value / (double)dur.timescale;
    return ds > 0 && cs >= ds - 0.05;
}

// seek 回开头继续播（循环的核心动作）
- (void)restartBgVideo {
    if (!self.bgPlayer) return;
    CMTime z = NBCMZero();
    [self.bgPlayer seekToTime:z
              toleranceBefore:z
               toleranceAfter:z];
    [self.bgPlayer play];
}

// 播完 seek 回开头，实现无缝续播（不用 AVPlayerLooper：这个 Theos SDK 里没有它的声明）
- (void)bgVideoDidEnd {
    [self restartBgVideo];
}

// 取视频首帧（AVAssetImageGenerator 全走运行时取类，不引入链接依赖）
- (void)videoFirstFrame:(NSString *)path completion:(void (^)(UIImage *img, BOOL ok))cb {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Class assetCls = objc_getClass("AVAsset");
        Class genCls = objc_getClass("AVAssetImageGenerator");
        if (!assetCls || !genCls || path.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(nil, NO); });
            return;
        }
        AVAsset *asset = NBMsgSend1(assetCls, @selector(assetWithURL:), [NSURL fileURLWithPath:path]);
        AVAssetImageGenerator *gen = NBMsgSend1(genCls, @selector(assetImageGeneratorWithAsset:), asset);
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(1600.0, 1600.0);
        CMTime at = NBCMZero();
        CMTime act;
        NSError *err = nil;
        CGImageRef cg = [gen copyCGImageAtTime:at actualTime:&act error:&err];
        UIImage *img = nil;
        if (cg) {
            img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(cg);
        } else {
            NBLOG(@"[视频] 取首帧失败 %@", err);
        }
        BOOL ok = (img != nil);
        dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(img, ok); });
    });
}

// 选一段视频（mp4/mov），拷到沙盒，循环静音播放
- (void)pickVideoFor:(NSString *)slot {
    self.pickingSlot = slot;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter videosFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    NBLOG(@"[选视频] 打开 picker");
    [self presentTracked:picker];
}

- (void)handleVideoResult:(PHPickerResult *)res {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block BOOL copied = NO;
        __block NSString *err = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        void (^load)(NSString *) = ^(NSString *tid) {
            [res.itemProvider loadFileRepresentationForTypeIdentifier:tid
                                                    completionHandler:^(NSURL *url, NSError *error) {
                if (url) {
                    [url startAccessingSecurityScopedResource];
                    NSString *dst = [NBLogDir() stringByAppendingPathComponent:@"bg_video.mov"];
                    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
                    copied = [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dst error:NULL];
                    if (!copied) err = [NSString stringWithFormat:@"拷贝失败 %@", error];
                    [url stopAccessingSecurityScopedResource];
                }
                dispatch_semaphore_signal(sem);
            }];
        };
        load(@"public.movie");
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0) {
            err = @"读取超时";
        }
        if (!copied) {
            // 有的视频标的是 mpeg-4 而不是 movie，再试一次
            load(@"public.mpeg-4");
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!copied) {
                [self alertDone:err.length ? [NSString stringWithFormat:@"视频读取失败：%@", err]
                                            : @"视频读取失败，请换一个（mp4/mov）"];
                return;
            }
            NSString *dst = [NBLogDir() stringByAppendingPathComponent:@"bg_video.mov"];
            [[NSUserDefaults standardUserDefaults] setObject:dst forKey:kKeyBgVideoPath];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgVideoRect];  // 换视频重置裁剪
            [self applyOverlays];        // 里面会挂视频层
            [self scheduleReapply];
            // 取首帧进裁剪页：选好想显示的画面范围（取消也应用，保持整幅画面）
            [self videoFirstFrame:dst completion:^(UIImage *img, BOOL ok) {
                if (!ok) {
                    NSString *modeNote2 = ([self bgMode] == 0) ? @"整个上半屏" : @"车控区域";
                    [self alertDone:[NSString stringWithFormat:@"背景视频已应用\n静音循环 · %@\n（取首帧失败，跳过裁剪）", modeNote2]];
                    return;
                }
                [self openVideoCropForImage:img];
            }];
        });
    });
}

// 打开视频画面裁剪页（裁剪框比例 = 区域比例，确定后无拉伸）
- (void)openVideoCropForImage:(UIImage *)img {
    if (!img) { [self alertDone:@"视频画面读取失败，请换一个"]; return; }
    CGFloat aspect = [self bgRegionAspect];
    __weak NBManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NBManager *me = weakSelf;
        if (!me) return;
        NBCropViewController *vc = [[NBCropViewController alloc] initWithImage:img aspect:aspect];
        vc.sourceImage = img;
        vc.cropTitle = @"裁剪视频画面";
        __weak NBCropViewController *weakVC = vc;
        vc.onCancel = ^{
            NBCropViewController *strongVC = weakVC;
            // 取消 = 保持整幅画面，但视频本身要生效
            [me applyOverlays];
            [me scheduleReapply];
            if (strongVC) [me dismissCropVC:strongVC];
        };
        vc.onFinishRect = ^(CGRect rect) {
            [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGRect(rect)
                                                     forKey:kKeyBgVideoRect];
            [me applyOverlays];
            [me scheduleReapply];
            NBCropViewController *strongVC = weakVC;
            if (strongVC) [me dismissCropVC:strongVC];
            NSString *modeNote2 = ([me bgMode] == 0) ? @"整个上半屏" : @"车控区域";
            [me alertDone:[NSString stringWithFormat:@"背景视频已应用\n静音循环 · 自动重播 · %@\n画面已按裁剪范围显示", modeNote2]];
        };
        [me presentTracked:vc];
        NBLOG(@"[裁剪] 打开视频裁剪页 aspect=%.3f", aspect);
    });
}

// 菜单入口：对已有背景视频重新裁剪画面
- (void)recropBgVideo {
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:kKeyBgVideoPath];
    if (p.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        [self alertDone:@"还没有设置背景视频"];
        return;
    }
    [self videoFirstFrame:p completion:^(UIImage *img, BOOL ok) {
        if (!ok) { [self alertDone:@"取视频画面失败，请重试"]; return; }
        [self openVideoCropForImage:img];
    }];
}

#pragma mark - 恢复

// 一键恢复：车辆 + 背景一起还原，并把相关记录清干净（显示方式的偏好保留）
- (void)oneKeyRestore {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kKeyVehPath];
    [d removeObjectForKey:kKeyVehRect];
    [d removeObjectForKey:kKeyBgPath];
    [d removeObjectForKey:kKeyBgRect];
    [d removeObjectForKey:kKeyBgVideoPath];
    [d removeObjectForKey:kKeyBgVideoRect];
    [self teardownVideoLayer];
    self.cachedBgImage = nil;
    self.cachedBgPath = nil;
    self.pendingStageRestore = YES;      // 万一此刻不在车控页，回车控页再还
    [self applyOverlays];
    [self scheduleReapply];
    if (![self hasAnyReplacement]) [self restoreOriginalStage];
    [self alertDone:@"已一键恢复\n车辆图和背景图都回到原样"];
    NBLOG(@"[恢复] 一键恢复");
}

- (void)restoreVehicle {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehPath];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyVehRect];
    [self applyOverlays];                    // veh 路径没了 -> applyOverlays 里会还原车图
    [self scheduleReapply];                  // 万一此刻不在车控页，回到首页时再兜一次
    if (![self hasAnyReplacement]) [self restoreOriginalStage];
    [self alertDone:@"已恢复车辆原图"];
    NBLOG(@"[恢复] 车辆图");
}

- (void)restoreBackground {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgPath];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kKeyBgRect];
    self.cachedBgImage = nil;
    self.cachedBgPath = nil;
    // 注意：这里**不能**先把 self.stageImage 清掉。
    // applyOverlays 靠「bgImg 为空 && stageImage 非空」才走 restoreStage，
    // 提前清空会让还原分支永远不成立 —— 之前"恢复背景要重启"就是这么来的。
    self.pendingStageRestore = YES;          // 不在车控页时，回车控页由看门狗补还原
    [self applyOverlays];
    [self scheduleReapply];
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
