#import "VaporNativeView.h"
#import <math.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static NSString *VaporArt(void) {
    return @"███     ███   ▄█████▄   ██████▄    ▄█████▄   ██████▄      ▄▄    ▄█████▄  ███     ███   ▄█████▄\n"
           @"███     ███  ███   ███  ███  ███  ███   ███  ███  ███    ███   ███   ███  ███   ███   ███   ███\n"
           @"███     ███  ███   ███  ███  ███  ███   ███  ███  ███    ███   ███▀▀▀▀▀▀   ███ ███    ███▀▀▀▀▀▀\n"
           @" ███   ███   █████████  ██████▀   ███   ███  ██████▀      ▀▀    ▀██████▄   █████      ▀██████▄\n"
           @"  ███ ███    ███   ███  ███       ███   ███  ███  ███               ███    ███             ███\n"
           @"   █████     ███   ███  ███        ▀█████▀   ███  ███          ████████     ███        ████████";
}

static NSString *VaporBlitSrc(void) {
    return @"#include <metal_stdlib>\n"
           "using namespace metal;\n"
           "struct VSOut { float4 pos [[position]]; float2 uv; };\n"
           "vertex VSOut vs_main(uint vid [[vertex_id]]) {\n"
           "  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
           "  float2 uv[3] = { float2(0,1), float2(2,1), float2(0,-1) };\n"
           "  VSOut o; o.pos = float4(p[vid], 0, 1); o.uv = uv[vid]; return o;\n"
           "}\n"
           "fragment float4 fs_main(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
           "  return tex.sample(s, in.uv);\n"
           "}\n";
}

typedef struct {
    unichar home;
    float hx, hy, x, y;
    float vx, vy, age;
    unichar shown;
    uint32_t rgb;
    float alpha;
} VCell;

typedef NS_ENUM(int, VaporEffect) {
    VaporDecrypt = 0,
    VaporBeams,
    VaporSpray,
    VaporSlide,
    VaporWipe,
    VaporBurn,
    VaporFireworks,
    VaporCrumble,
    VaporPrint,
    VaporHighlight,
    VaporExpand,
    VaporPour,
    VaporScatter,
    VaporWaves,
    VaporColorShift,
    VaporBlackhole,
    VaporSlice,
    VaporSwarm,
    VaporEffectCount
};

static uint32_t Pack(float r, float g, float b) {
    int R = (int)(fminf(1, fmaxf(0, r)) * 255);
    int G = (int)(fminf(1, fmaxf(0, g)) * 255);
    int B = (int)(fminf(1, fmaxf(0, b)) * 255);
    return (uint32_t)((R << 16) | (G << 8) | B);
}

static unichar RandGlyph(void) {
    static const unichar g[] = {
        0x30A2, 0x30AB, 0x30B5, 0x30BF, 0x30CA, 0x30CF, 0x30DE, 0x30E4, 0x30E9,
        '0', '1', '7', 'Z', '#', '*', '+', 0x2588, 0x2591, 0x2592
    };
    return g[arc4random_uniform((uint32_t)(sizeof(g) / sizeof(g[0])))];
}

static void VaporLog(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSArray<NSString *> *paths = @[
        @"/tmp/omacosy-vapor-saver.log",
        [NSHomeDirectory() stringByAppendingPathComponent:@"vapor-saver.log"]
    ];
    for (NSString *path in paths) {
        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (f) {
            fputs(line.UTF8String, f);
            fclose(f);
        }
    }
}

@implementation VaporNativeView {
    VCell *_cells;
    NSInteger _count;
    NSInteger _cols;
    NSInteger _rows;
    CGFloat _cellW;
    CGFloat _cellH;
    VaporEffect _effect;
    int _lastEffect;
    int _phase;
    NSInteger _frame;
    NSInteger _phaseLen;
    BOOL _running;
    NSInteger _holdFrames;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLSamplerState> _sampler;
    id<MTLTexture> _tex;
    uint8_t *_pixels;
    NSInteger _pixW;
    NSInteger _pixH;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:device];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.device = MTLCreateSystemDefaultDevice();
        [self commonInit];
    }
    return self;
}

- (NSSize)layoutSize {
    NSSize b = self.bounds.size;
    if (b.width < 400 || b.height < 200) {
        return NSMakeSize(1280, 720);
    }
    return b;
}

- (void)syncInternalDrawable {
    NSSize layout = [self layoutSize];
    CGFloat scale = self.window.backingScaleFactor;
    if (scale < 1) {
        scale = 2;
    }
    if (self.bounds.size.width < 400) {
        self.autoResizeDrawable = NO;
        self.drawableSize = CGSizeMake(layout.width * scale, layout.height * scale);
    } else {
        self.autoResizeDrawable = YES;
    }
    if ([self.layer isKindOfClass:[CAMetalLayer class]]) {
        ((CAMetalLayer *)self.layer).opaque = YES;
    }
}

- (void)commonInit {
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.preferredFramesPerSecond = 30;
    self.enableSetNeedsDisplay = NO;
    self.paused = NO;
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.layer.opaque = YES;
    self.delegate = self;
    [self syncInternalDrawable];
    [self buildGPU];
    [self rebuild];
    [self paintCPU];
    VaporLog([NSString stringWithFormat:@"native init bounds=%.0fx%.0f layout=%.0fx%.0f device=%@",
              self.bounds.size.width, self.bounds.size.height,
              [self layoutSize].width, [self layoutSize].height, self.device]);
}

- (void)dealloc {
    free(_cells);
    free(_pixels);
}

- (void)buildGPU {
    id<MTLDevice> device = self.device;
    if (!device) {
        VaporLog(@"no metal device");
        return;
    }
    _queue = [device newCommandQueue];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:VaporBlitSrc() options:nil error:&error];
    if (!library) {
        VaporLog([NSString stringWithFormat:@"shader fail %@", error]);
        return;
    }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vs_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fs_main"];
    desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_pipeline) {
        VaporLog([NSString stringWithFormat:@"pipeline fail %@", error]);
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];
}

- (void)start {
    _running = YES;
    _lastEffect = -1;
    [self rebuild];
    _holdFrames = self.preview ? NSIntegerMax : 30;
    [self paintCPU];
    self.paused = NO;
    VaporLog([NSString stringWithFormat:@"native start preview=%d hold=%ld", (int)self.preview, (long)_holdFrames]);
}

- (void)stop {
    _running = NO;
    self.paused = YES;
    VaporLog(@"native stop");
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    [self syncInternalDrawable];
    [self rebuild];
}

- (void)drawInMTKView:(MTKView *)view {
    [self syncInternalDrawable];
    [self tick];
    if (!_queue) {
        return;
    }
    id<MTLTexture> tex = [self uploadTexture];
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) {
        return;
    }
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (_pipeline && tex && _sampler) {
        [enc setRenderPipelineState:_pipeline];
        [enc setFragmentTexture:tex atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

- (void)rebuild {
    NSArray<NSString *> *lines = [VaporArt() componentsSeparatedByString:@"\n"];
    _rows = lines.count;
    _cols = 1;
    for (NSString *line in lines) {
        _cols = MAX(_cols, (NSInteger)line.length);
    }
    NSSize sz = [self layoutSize];
    CGFloat fitW = floor(sz.width / MAX(_cols, 1));
    CGFloat fitH = floor(sz.height / MAX(_rows * 2, 1));
    _cellW = MAX(2, MIN(14, MIN(fitW, fitH)));
    _cellH = _cellW * 2;
    CGFloat originX = floor((sz.width - _cols * _cellW) / 2);
    CGFloat originY = floor((sz.height - _rows * _cellH) / 2);
    NSInteger n = 0;
    for (NSInteger r = 0; r < _rows; r++) {
        NSString *line = r < (NSInteger)lines.count ? lines[r] : @"";
        for (NSInteger c = 0; c < (NSInteger)line.length; c++) {
            if ([line characterAtIndex:c] != ' ') {
                n++;
            }
        }
    }
    free(_cells);
    _cells = calloc((size_t)n, sizeof(VCell));
    _count = 0;
    for (NSInteger r = 0; r < _rows; r++) {
        NSString *line = r < (NSInteger)lines.count ? lines[r] : @"";
        for (NSInteger c = 0; c < (NSInteger)line.length; c++) {
            unichar ch = [line characterAtIndex:c];
            if (ch == ' ') {
                continue;
            }
            VCell cell = {0};
            cell.home = ch;
            cell.shown = ch;
            cell.hx = originX + c * _cellW;
            cell.hy = originY + r * _cellH;
            cell.x = cell.hx;
            cell.y = cell.hy;
            cell.alpha = 1;
            cell.rgb = 0x9ece6a;
            _cells[_count++] = cell;
        }
    }
}

- (void)nextEffect {
    int next;
    do {
        next = (int)arc4random_uniform((uint32_t)VaporEffectCount);
    } while (next == _lastEffect && VaporEffectCount > 1);
    _lastEffect = next;
    _effect = (VaporEffect)next;
    _phase = 0;
    _frame = 0;
    _phaseLen = 48 + (int)arc4random_uniform(24);
    NSSize sz = [self layoutSize];
    for (NSInteger i = 0; i < _count; i++) {
        VCell *c = &_cells[i];
        c->x = c->hx;
        c->y = c->hy;
        c->vx = 0;
        c->vy = 0;
        c->age = (float)i / MAX(_count, 1);
        c->shown = c->home;
        c->alpha = 0;
        c->rgb = 0x9ece6a;
        switch (_effect) {
            case VaporSpray:
            case VaporFireworks:
            case VaporExpand:
                c->x = sz.width * 0.5f;
                c->y = sz.height * 0.5f;
                break;
            case VaporSlide:
                c->x = c->hx + (i % 2 ? -sz.width : sz.width);
                break;
            case VaporPour:
                c->y = -_cellH * (2 + (int)arc4random_uniform(20));
                c->vy = 6 + arc4random_uniform(8);
                break;
            case VaporScatter:
            case VaporCrumble:
                c->x = arc4random_uniform((uint32_t)MAX(sz.width, 2));
                c->y = arc4random_uniform((uint32_t)MAX(sz.height, 2));
                break;
            case VaporSwarm:
                c->x = arc4random_uniform((uint32_t)MAX(sz.width, 2));
                c->y = -20;
                break;
            default:
                break;
        }
    }
}

- (float)progress {
    return MIN(1.f, _frame / (float)MAX(_phaseLen, 1));
}

- (void)tick {
    if (!_running) {
        [self paintCPU];
        return;
    }
    if (_holdFrames > 0) {
        if (_holdFrames != NSIntegerMax) {
            _holdFrames--;
        } else {
            _frame++;
            for (NSInteger i = 0; i < _count; i++) {
                VCell *c = &_cells[i];
                c->x = c->hx;
                c->y = c->hy;
                c->shown = c->home;
                c->alpha = 1;
                float h = fmodf(_frame * 0.02f + i * 0.03f, 1.f);
                c->rgb = Pack(0.35f + 0.35f * sinf(h * 6), 0.75f + 0.25f * sinf(h * 6 + 2), 0.35f + 0.3f * sinf(h * 6 + 4));
            }
        }
        if (_holdFrames == 0) {
            [self nextEffect];
        }
        [self paintCPU];
        return;
    }
    float p = [self progress];
    NSSize sz = [self layoutSize];
    for (NSInteger i = 0; i < _count; i++) {
        VCell *c = &_cells[i];
        float delay = c->age * 0.65f;
        float local = MAX(0, MIN(1, (p - delay) / MAX(0.001f, 1 - delay)));
        switch (_effect) {
            case VaporDecrypt:
                c->alpha = _phase == 2 ? 1 - p : MIN(1, p * 2);
                c->shown = (_phase == 0 && local < 0.85f) ? RandGlyph() : c->home;
                c->x = c->hx;
                c->y = c->hy;
                break;
            case VaporBeams: {
                float beam = fmodf((_frame * 0.08f) + c->hy * 0.01f, 1.f);
                float lit = fabs((double)(c->hx / MAX(sz.width, 1) - beam)) < 0.08 || _phase > 0;
                c->alpha = _phase == 2 ? 1 - p : (lit ? 1 : 0.12f);
                c->rgb = lit ? 0xd4ff9a : 0x3a6b32;
                c->shown = c->home;
                break;
            }
            case VaporSpray:
            case VaporFireworks:
            case VaporExpand:
                c->x += (c->hx - c->x) * (0.12f + local * 0.2f);
                c->y += (c->hy - c->y) * (0.12f + local * 0.2f);
                c->alpha = _phase == 2 ? 1 - p : MIN(1, local * 1.5f);
                c->shown = c->home;
                if (_effect == VaporFireworks && _phase == 0 && local < 0.4f) {
                    c->shown = RandGlyph();
                }
                break;
            case VaporSlide:
            case VaporWipe:
                if (_effect == VaporWipe) {
                    c->alpha = (c->hx / MAX(sz.width, 1) < (_phase == 2 ? 1 - p : p)) ? 1 : 0;
                    c->x = c->hx;
                    c->y = c->hy;
                } else {
                    c->x += (c->hx - c->x) * 0.18f;
                    c->alpha = _phase == 2 ? 1 - p : 1;
                }
                c->shown = c->home;
                break;
            case VaporBurn:
                c->alpha = _phase == 2 ? 1 - p : MIN(1, local * 1.4f);
                c->rgb = Pack(1.f, 0.35f + local * 0.5f, 0.08f + local * 0.2f);
                if (_phase == 1) {
                    c->rgb = 0x9ece6a;
                }
                c->shown = c->home;
                break;
            case VaporCrumble:
            case VaporScatter:
                if (_phase == 2) {
                    c->vy += 0.35f;
                    c->y += c->vy;
                    c->x += (i % 2 ? -1 : 1) * 0.8f;
                    c->alpha = 1 - p;
                } else {
                    c->x += (c->hx - c->x) * 0.16f;
                    c->y += (c->hy - c->y) * 0.16f;
                    c->alpha = MIN(1, local * 1.3f);
                }
                c->shown = c->home;
                break;
            case VaporPrint:
                c->alpha = ((float)i / MAX(_count, 1) < (_phase == 2 ? 1 - p : p)) ? 1 : 0;
                c->shown = c->home;
                c->x = c->hx;
                c->y = c->hy;
                break;
            case VaporHighlight: {
                float wave = 0.5f + 0.5f * sinf(_frame * 0.18f + c->hx * 0.04f);
                c->alpha = _phase == 2 ? 1 - p : 1;
                c->rgb = Pack(0.4f + wave * 0.6f, 0.85f + wave * 0.15f, 0.3f + wave * 0.4f);
                c->shown = c->home;
                break;
            }
            case VaporPour:
                if (_phase == 2) {
                    c->y += 8;
                    c->alpha = 1 - p;
                } else if (c->y < c->hy) {
                    c->y += c->vy;
                    if (c->y > c->hy) {
                        c->y = c->hy;
                    }
                    c->shown = (c->y < c->hy - 1) ? RandGlyph() : c->home;
                    c->alpha = 1;
                } else {
                    c->shown = c->home;
                    c->alpha = 1;
                }
                break;
            case VaporWaves: {
                float w = sinf(_frame * 0.14f + c->hx * 0.05f) * 6;
                c->x = c->hx;
                c->y = c->hy + (_phase == 1 ? w : w * local);
                c->alpha = _phase == 2 ? 1 - p : MIN(1, p * 2);
                c->shown = c->home;
                break;
            }
            case VaporColorShift: {
                float h = fmodf(_frame * 0.02f + i * 0.03f, 1.f);
                c->rgb = Pack(0.3f + 0.4f * sinf(h * 6), 0.6f + 0.4f * sinf(h * 6 + 2), 0.4f + 0.4f * sinf(h * 6 + 4));
                c->alpha = _phase == 2 ? 1 - p : 1;
                c->shown = c->home;
                break;
            }
            case VaporBlackhole: {
                float cx = sz.width * 0.5f, cy = sz.height * 0.5f;
                if (_phase == 0) {
                    float t = 1 - local;
                    c->x = c->hx * local + cx * t;
                    c->y = c->hy * local + cy * t;
                    c->alpha = local;
                } else if (_phase == 2) {
                    c->x += (cx - c->x) * 0.2f;
                    c->y += (cy - c->y) * 0.2f;
                    c->alpha = 1 - p;
                } else {
                    c->x = c->hx;
                    c->y = c->hy;
                    c->alpha = 1;
                }
                c->shown = c->home;
                break;
            }
            case VaporSlice:
                c->x = c->hx + ((_phase == 2 ? p : 1 - local) * ((i % 2) ? 40 : -40));
                c->alpha = _phase == 2 ? 1 - p : MIN(1, local * 1.4f);
                c->shown = c->home;
                break;
            case VaporSwarm:
                c->x += (c->hx - c->x) * 0.14f;
                c->y += (c->hy - c->y) * 0.14f;
                c->alpha = _phase == 2 ? 1 - p : MIN(1, local * 1.5f);
                c->shown = (_phase == 0 && local < 0.7f) ? RandGlyph() : c->home;
                break;
            case VaporEffectCount:
                break;
        }
    }
    _frame++;
    if (_frame >= _phaseLen) {
        _frame = 0;
        _phase++;
        if (_phase == 1) {
            _phaseLen = 36;
        } else if (_phase == 2) {
            _phaseLen = 36;
        } else {
            [self nextEffect];
        }
    }
    [self paintCPU];
}

static void FillBGRA(uint8_t *buf, NSInteger pw, NSInteger ph, int x, int y, int rw, int rh,
                     uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    if (!buf || rw < 1 || rh < 1) {
        return;
    }
    for (int yy = y; yy < y + rh; yy++) {
        if (yy < 0 || yy >= ph) {
            continue;
        }
        for (int xx = x; xx < x + rw; xx++) {
            if (xx < 0 || xx >= pw) {
                continue;
            }
            NSInteger i = ((NSInteger)yy * pw + xx) * 4;
            buf[i + 0] = b;
            buf[i + 1] = g;
            buf[i + 2] = r;
            buf[i + 3] = a;
        }
    }
}

- (void)paintCPU {
    NSSize layout = [self layoutSize];
    CGFloat scale = 2;
    NSInteger pw = MAX(2, (NSInteger)llround(layout.width * scale));
    NSInteger ph = MAX(2, (NSInteger)llround(layout.height * scale));
    if (_pixels == NULL || pw != _pixW || ph != _pixH) {
        free(_pixels);
        _pixW = pw;
        _pixH = ph;
        _pixels = calloc((size_t)pw * (size_t)ph * 4, 1);
    }
    NSInteger count = pw * ph;
    for (NSInteger i = 0; i < count; i++) {
        _pixels[i * 4 + 0] = 0;
        _pixels[i * 4 + 1] = 0;
        _pixels[i * 4 + 2] = 0;
        _pixels[i * 4 + 3] = 255;
    }
    if (_count == 0) {
        [self rebuild];
    }
    for (NSInteger i = 0; i < _count; i++) {
        VCell c = _cells[i];
        if (c.alpha <= 0.02f) {
            continue;
        }
        uint8_t r = (uint8_t)(((c.rgb >> 16) & 255) * c.alpha);
        uint8_t g = (uint8_t)(((c.rgb >> 8) & 255) * c.alpha);
        uint8_t b = (uint8_t)((c.rgb & 255) * c.alpha);
        int x = (int)llround(c.x * scale);
        int y = (int)llround(c.y * scale);
        int w = MAX(1, (int)llround(_cellW * scale));
        int h = MAX(1, (int)llround(_cellH * scale));
        if (c.shown == 0x2584) {
            FillBGRA(_pixels, pw, ph, x, y + h / 2, w, h - h / 2, r, g, b, 255);
        } else if (c.shown == 0x2580) {
            FillBGRA(_pixels, pw, ph, x, y, w, h / 2, r, g, b, 255);
        } else {
            FillBGRA(_pixels, pw, ph, x, y, w, h, r, g, b, 255);
        }
    }
}

- (id<MTLTexture>)uploadTexture {
    if (_pixels == NULL) {
        [self paintCPU];
    }
    if (_pixels == NULL || !self.device) {
        return nil;
    }
    if (!_tex || (NSInteger)_tex.width != _pixW || (NSInteger)_tex.height != _pixH) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:(NSUInteger)_pixW
                                                                                    height:(NSUInteger)_pixH
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        _tex = [self.device newTextureWithDescriptor:td];
    }
    MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)_pixW, (NSUInteger)_pixH);
    [_tex replaceRegion:region mipmapLevel:0 withBytes:_pixels bytesPerRow:(NSUInteger)(_pixW * 4)];
    return _tex;
}

- (NSBitmapImageRep *)debugSnapshot {
    [self paintCPU];
    if (_pixels == NULL) {
        return nil;
    }
    return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&_pixels
                                                   pixelsWide:_pixW
                                                   pixelsHigh:_pixH
                                                bitsPerSample:8
                                              samplesPerPixel:4
                                                     hasAlpha:YES
                                                     isPlanar:NO
                                               colorSpaceName:NSDeviceRGBColorSpace
                                                 bitmapFormat:NSBitmapFormatThirtyTwoBitLittleEndian
                                                  bytesPerRow:_pixW * 4
                                                 bitsPerPixel:32];
}

@end
