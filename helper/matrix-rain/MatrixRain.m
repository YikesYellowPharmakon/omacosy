#import "MatrixRain.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <CoreImage/CoreImage.h>
#import <math.h>

typedef struct {
    float iTime;
    float pad0;
    simd_float2 iResolution;
    simd_float4 colBg;
    simd_float4 colHead;
    simd_float4 colRainA;
    simd_float4 colRainB;
    float cellH;
    float dpr;
    float period;
    float birth;
    float wordmark;
    float trapBoost;
    float pad2;
    float pad3;
} RainUniforms;

static NSString *RainResourceDir(void) {
    NSString *bundle = [[NSBundle bundleForClass:[MatrixRainView class]] resourcePath];
    if (bundle.length && [[NSFileManager defaultManager] fileExistsAtPath:[bundle stringByAppendingPathComponent:@"glyphs.png"]])
        return bundle;
    NSString *home = [NSHomeDirectory() stringByAppendingPathComponent:@".local/share/omacosy/helper/matrix-rain"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"glyphs.png"]])
        return home;
    return [[NSBundle mainBundle] resourcePath] ?: home;
}

static simd_float4 RainColor(unsigned int rgb) {
    return simd_make_float4(((rgb >> 16) & 0xff) / 255.f,
                            ((rgb >> 8) & 0xff) / 255.f,
                            (rgb & 0xff) / 255.f,
                            1.f);
}

@implementation MatrixRainView {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _atlas;
    id<MTLSamplerState> _sampler;
    id<MTLBuffer> _uniforms;
    CFTimeInterval _last;
    CFTimeInterval _accum;
    float _elapsed;
    float _birth;
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

- (void)commonInit {
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.preferredFramesPerSecond = 30;
    self.enableSetNeedsDisplay = NO;
    ((MTKView *)self).paused = NO;
    self.autoResizeDrawable = YES;
    self.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.delegate = self;
    _wordmark = NO;
    _calm = NO;
    _cellHeight = 16.f;
    _last = -1;
    _elapsed = 0;
    _birth = 0;
    _accum = 0;
    [self buildGPU];
}

- (void)restart {
    _elapsed = 0;
    _birth = 0;
    _accum = 0;
    _last = -1;
}

- (void)setClock:(float)elapsed birth:(float)birth {
    _elapsed = elapsed;
    _birth = birth;
    _accum = 0;
    _last = -1;
}

- (void)buildGPU {
    id<MTLDevice> device = self.device;
    if (!device) return;
    _queue = [device newCommandQueue];
    NSString *dir = RainResourceDir();
    NSError *error = nil;
    id<MTLLibrary> library = nil;
    NSString *libPath = [dir stringByAppendingPathComponent:@"default.metallib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:libPath])
        library = [device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&error];
    if (!library) {
        NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"matrix.metal"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
        if (src.length)
            library = [device newLibraryWithSource:src options:nil error:&error];
    }
    if (!library) {
        NSLog(@"matrix-rain: shader load failed: %@", error);
        return;
    }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vs_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fs_main"];
    desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    _uniforms = [device newBufferWithLength:sizeof(RainUniforms) options:MTLResourceStorageModeShared];

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];

    NSString *atlasPath = [dir stringByAppendingPathComponent:@"glyphs.png"];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:atlasPath];
    if (!image) return;
    NSRect proposed = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cg = [image CGImageForProposedRect:&proposed context:nil hints:nil];
    if (!cg) return;
    NSUInteger width = CGImageGetWidth(cg);
    NSUInteger height = CGImageGetHeight(cg);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    _atlas = [device newTextureWithDescriptor:td];
    NSUInteger bpr = width * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * height];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, bpr, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(ctx);
    [_atlas replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:bpr];
}

- (void)advanceClock {
    CFTimeInterval now = CACurrentMediaTime();
    if (_last < 0) _last = now;
    CFTimeInterval dt = now - _last;
    _last = now;
    if (self.paused) return;
    _elapsed = fmodf(_elapsed + (float)dt, 3600.f);
    if (_birth < 13.f)
        _birth = fminf(13.f, _birth + (float)dt);
    _accum = 0;
}

- (void)syncDrawableToScreen {
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
    self.wantsLayer = YES;
    if (fabs(self.layer.contentsScale - scale) > 0.01)
        self.layer.contentsScale = scale;
}

- (void)fillUniforms:(RainUniforms *)u size:(CGSize)size {
    [self syncDrawableToScreen];
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    float dpr = (float)(screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.f);
    CGSize logical = self.bounds.size;
    if (logical.width < 8 || logical.height < 8)
        logical = size;
    float cellH = self.cellHeight > 4.f ? self.cellHeight : 16.f;
    u->iTime = _elapsed;
    u->pad0 = 0;
    u->iResolution = simd_make_float2((float)logical.width, (float)logical.height);
    u->colBg = RainColor(0x000000);
    u->colHead = RainColor(0xE2FFE2);
    u->colRainA = RainColor(0x7EBB7E);
    u->colRainB = RainColor(0x0E3A12);
    u->dpr = dpr;
    u->period = 3600.f;
    u->birth = _birth;
    u->wordmark = _wordmark ? 1.f : 0.f;
    u->trapBoost = 0.f;
    u->cellH = cellH;
    u->pad2 = cellH * 0.47f;
    u->pad3 = 0;
}

- (void)encodePass:(id<MTLRenderCommandEncoder>)enc size:(CGSize)size {
    if (!_pipeline || !_atlas) return;
    RainUniforms u;
    [self fillUniforms:&u size:size];
    memcpy(_uniforms.contents, &u, sizeof(u));
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBuffer:_uniforms offset:0 atIndex:0];
    [enc setFragmentBuffer:_uniforms offset:0 atIndex:0];
    [enc setFragmentTexture:_atlas atIndex:0];
    [enc setFragmentSamplerState:_sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    [self advanceClock];
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass) return;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [self encodePass:enc size:view.bounds.size];
    [enc endEncoding];
    if (view.currentDrawable)
        [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

+ (BOOL)writeSnapshotToURL:(NSURL *)url size:(CGSize)size {
    return [self writeSnapshotToURL:url size:size wordmark:NO];
}

+ (BOOL)writeSnapshotToURL:(NSURL *)url size:(CGSize)size wordmark:(BOOL)wordmark {
    MatrixRainView *view = [[MatrixRainView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    view.framebufferOnly = NO;
    view.wordmark = wordmark;
    view.cellHeight = 16.f;
    view->_elapsed = wordmark ? 72.f : 9.f;
    view->_birth = 13.f;
    id<MTLDevice> device = view.device;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)size.width
                                                                                 height:(NSUInteger)size.height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    if (!tex) return NO;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = tex;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLCommandBuffer> cmd = [view->_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [view encodePass:enc size:size];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    CIImage *ci = [[CIImage alloc] initWithMTLTexture:tex options:@{kCIImageColorSpace: [NSNull null]}];
    if (!ci) return NO;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(1, -1)];
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(0, size.height)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:ci];
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image addRepresentation:rep];
    CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return NO;
    NSBitmapImageRep *png = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData *data = [png representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [data writeToURL:url atomically:YES];
}

@end
