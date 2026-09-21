#import <ScreenSaver/ScreenSaver.h>
#import <math.h>

enum {
    kVaporScatter = 0,
    kVaporSpray,
    kVaporFireworks,
    kVaporSlide,
    kVaporSwarm,
    kVaporBlackhole,
    kVaporWaves,
    kVaporSlice,
    kVaporBeams,
    kVaporExpand,
    kVaporCrumble,
    kVaporPour,
    kVaporFXCount
};

typedef struct {
    float hx, hy, ox, oy;
    uint8_t r, g, b;
} VaporPix;

@interface OmacosyVaporView : ScreenSaverView
@end

@implementation OmacosyVaporView {
    VaporPix *_pix;
    NSInteger _n;
    int _simW;
    int _simH;
    int _cell;
    uint8_t *_buf;
    int _fx;
    int _phase;
    float _t;
    float _phaseDur;
    CFAbsoluteTime _last;
    BOOL _ready;
}

- (BOOL)isOpaque {
    return YES;
}

- (NSImage *)artImage {
    NSArray<NSString *> *candidates = @[
        [[NSBundle bundleForClass:[self class]] pathForResource:@"preview" ofType:@"png"] ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @".local/share/omacosy/helper/oligarchy-screensaver/share/preview.png"],
        @"/Users/ye/Projects/mac-theme/.theme-imports/oligarchy-screensaver/share/preview.png"
    ];
    for (NSString *path in candidates) {
        if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return [[NSImage alloc] initWithContentsOfFile:path];
        }
    }
    return nil;
}

- (void)loadPixelsForPreview:(BOOL)isPreview {
    if (isPreview) {
        _simW = 320;
        _simH = 180;
        _cell = 8;
    } else {
        _simW = 960;
        _simH = 540;
        _cell = 4;
    }
    NSImage *art = [self artImage];
    if (art == nil) {
        return;
    }
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:art.TIFFRepresentation];
    if (rep == nil) {
        return;
    }
    NSInteger srcW = rep.pixelsWide;
    NSInteger srcH = rep.pixelsHigh;
    const int step = isPreview ? 24 : 8;
    NSInteger cap = ((srcW + step - 1) / step) * ((srcH + step - 1) / step);
    _pix = (VaporPix *)calloc((size_t)cap, sizeof(VaporPix));
    _n = 0;
    for (NSInteger y = 0; y < srcH; y += step) {
        for (NSInteger x = 0; x < srcW; x += step) {
            NSColor *c = [rep colorAtX:x y:y];
            if (c == nil) {
                continue;
            }
            c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat r = 0, g = 0, b = 0, a = 1;
            [c getRed:&r green:&g blue:&b alpha:&a];
            if ((r + g + b) < 0.14 || a < 0.2) {
                continue;
            }
            VaporPix p;
            p.hx = (float)x / (float)srcW * (float)_simW;
            p.hy = (float)y / (float)srcH * (float)_simH;
            p.ox = 0;
            p.oy = 0;
            p.r = (uint8_t)(r * 255);
            p.g = (uint8_t)(g * 255);
            p.b = (uint8_t)(b * 255);
            _pix[_n++] = p;
        }
    }
    _buf = (uint8_t *)calloc((size_t)(_simW * _simH), 4);
    _ready = _n > 0 && _buf != NULL;
}

- (void)armEffect:(int)fx {
    _fx = fx;
    float W = (float)_simW;
    float H = (float)_simH;
    float cx = W * 0.5f;
    float cy = H * 0.42f;
    for (NSInteger i = 0; i < _n; i++) {
        VaporPix *p = &_pix[i];
        float ang = (float)arc4random() / (float)UINT32_MAX * 6.2831853f;
        float rad = 70.f + (float)(arc4random_uniform(420));
        switch (fx) {
            case kVaporSpray:
                p->ox = cosf(ang) * rad;
                p->oy = sinf(ang) * rad;
                break;
            case kVaporFireworks:
                p->ox = (p->hx - cx) * 0.4f + (float)((int)arc4random_uniform(170) - 85);
                p->oy = -130.f - (float)arc4random_uniform(190);
                break;
            case kVaporSlide:
                p->ox = (p->hx < cx) ? -W : W;
                p->oy = (float)((int)arc4random_uniform(30) - 15);
                break;
            case kVaporSwarm:
                p->ox = cosf(ang) * 110.f;
                p->oy = sinf(ang) * 110.f;
                break;
            case kVaporBlackhole:
                p->ox = cx - p->hx;
                p->oy = cy - p->hy;
                break;
            case kVaporWaves:
                p->ox = sinf(p->hy * 0.045f + p->hx * 0.01f) * 150.f;
                p->oy = cosf(p->hx * 0.04f) * 36.f;
                break;
            case kVaporSlice:
                p->ox = (((int)(p->hy / 8.f) & 1) ? 1.f : -1.f) * W * 0.7f;
                p->oy = 0;
                break;
            case kVaporBeams:
                p->ox = (((int)(p->hy / 6.f) & 1) ? W : -W);
                p->oy = 0;
                break;
            case kVaporExpand:
                p->ox = (p->hx - cx) * 1.9f;
                p->oy = (p->hy - cy) * 1.9f;
                break;
            case kVaporCrumble:
                p->ox = (float)((int)arc4random_uniform(50) - 25);
                p->oy = H - p->hy + (float)arc4random_uniform(90);
                break;
            case kVaporPour:
                p->ox = (float)((int)arc4random_uniform(36) - 18);
                p->oy = -p->hy - 24.f - (float)arc4random_uniform(140);
                break;
            case kVaporScatter:
            default:
                p->ox = (float)(arc4random_uniform((uint32_t)W)) - p->hx;
                p->oy = (float)(arc4random_uniform((uint32_t)H)) - p->hy;
                break;
        }
    }
}

- (void)setPhase:(int)phase {
    _phase = phase;
    _t = 0;
    switch (phase) {
        case 0: _phaseDur = 1.7f; break;
        case 1: _phaseDur = 0.35f; break;
        case 2: _phaseDur = 1.5f; break;
        default: _phaseDur = 0.7f; break;
    }
}

- (void)nextEffect {
    int fx = (int)arc4random_uniform(kVaporFXCount);
    if (fx == _fx) {
        fx = (fx + 1) % kVaporFXCount;
    }
    [self armEffect:fx];
    [self setPhase:0];
}

static float vaporEase(float t) {
    t = fminf(1.f, fmaxf(0.f, t));
    return t * t * (3.f - 2.f * t);
}

- (void)stepWithDt:(float)dt {
    if (!_ready) {
        return;
    }
    _t += dt / _phaseDur;
    if (_t >= 1.f) {
        if (_phase >= 3) {
            [self nextEffect];
        } else {
            [self setPhase:_phase + 1];
        }
    }
}

- (void)renderBuffer {
    if (!_ready) {
        return;
    }
    uint32_t *px = (uint32_t *)_buf;
    NSInteger count = (NSInteger)_simW * (NSInteger)_simH;
    for (NSInteger i = 0; i < count; i++) {
        px[i] = 0xFF000000u;
    }
    float u;
    if (_phase == 0) {
        u = vaporEase(_t);
    } else if (_phase == 1) {
        u = 1.f;
    } else if (_phase == 2) {
        u = 1.f - vaporEase(_t);
    } else {
        u = 0.f;
    }
    const int s = _cell;
    for (NSInteger i = 0; i < _n; i++) {
        VaporPix p = _pix[i];
        int x0 = (int)lroundf(p.hx + p.ox * u);
        int y0 = (int)lroundf(p.hy + p.oy * u);
        for (int dy = 0; dy < s; dy++) {
            int y = y0 + dy;
            if ((unsigned)y >= (unsigned)_simH) {
                continue;
            }
            uint8_t *row = _buf + (y * _simW) * 4;
            for (int dx = 0; dx < s; dx++) {
                int x = x0 + dx;
                if ((unsigned)x >= (unsigned)_simW) {
                    continue;
                }
                uint8_t *d = row + x * 4;
                d[0] = p.r;
                d[1] = p.g;
                d[2] = p.b;
                d[3] = 255;
            }
        }
    }
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1.0 / 30.0];
        [self loadPixelsForPreview:isPreview];
        [self armEffect:kVaporScatter];
        [self setPhase:0];
        _t = 0.28f;
        _last = CFAbsoluteTimeGetCurrent();
        NSString *line = [NSString stringWithFormat:@"%@ jump-init preview=%d pixels=%ld bounds=%.0fx%.0f\n",
                          [NSDate date], (int)isPreview, (long)_n, frame.size.width, frame.size.height];
        NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/omacosy-vapor-jump.log"];
        FILE *f = fopen(log.fileSystemRepresentation, "a");
        if (f) {
            fputs(line.UTF8String, f);
            fclose(f);
        }
    }
    return self;
}

- (void)dealloc {
    free(_pix);
    free(_buf);
}

- (void)startAnimation {
    [super startAnimation];
    _last = CFAbsoluteTimeGetCurrent();
}

- (void)animateOneFrame {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    float dt = (float)(now - _last);
    _last = now;
    if (dt < 0.f) {
        dt = 0.016f;
    }
    if (dt > 0.08f) {
        dt = 0.032f;
    }
    [self stepWithDt:dt];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(self.bounds);
    if (!_ready) {
        return;
    }
    [self renderBuffer];
    unsigned char *planes[1] = { _buf };
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:planes
                      pixelsWide:_simW
                      pixelsHigh:_simH
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                     bytesPerRow:_simW * 4
                    bitsPerPixel:32];
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(_simW, _simH)];
    [img addRepresentation:rep];
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    NSImageInterpolation old = gc.imageInterpolation;
    gc.imageInterpolation = NSImageInterpolationNone;
    [img drawInRect:self.bounds
           fromRect:NSZeroRect
          operation:NSCompositingOperationCopy
           fraction:1.0];
    gc.imageInterpolation = old;
}

- (BOOL)hasConfigureSheet {
    return NO;
}

- (BOOL)writeProofTo:(NSString *)path {
    if (!_ready) {
        return NO;
    }
    [self renderBuffer];
    unsigned char *planes[1] = { _buf };
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:planes
                      pixelsWide:_simW
                      pixelsHigh:_simH
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                     bytesPerRow:_simW * 4
                    bitsPerPixel:32];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

@end
