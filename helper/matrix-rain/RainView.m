#import "RainView.h"
#import <CoreText/CoreText.h>

typedef struct {
    float head;
    float speed;
    int length;
    int seed;
} RainColumn;

@implementation RainView {
    RainColumn *_cols;
    int _colCount;
    int _rowCount;
    CGFloat _cellW;
    CGFloat _cellH;
    NSTimer *_timer;
    uint32_t _bg;
    uint32_t _accent;
    uint32_t _head;
    NSArray<NSString *> *_glyphs;
    NSArray<NSImage *> *_atlas;
    BOOL _paused;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _cellW = 18;
        _cellH = 22;
        _bg = 0x080C08;
        _accent = 0x7BAE4E;
        _head = 0xE2FFE2;
        _glyphs = @[
            @"ｱ",@"ｲ",@"ｳ",@"ｴ",@"ｵ",@"ｶ",@"ｷ",@"ｸ",@"ｹ",@"ｺ",
            @"ｻ",@"ｼ",@"ｽ",@"ｾ",@"ｿ",@"ﾀ",@"ﾁ",@"ﾂ",@"ﾃ",@"ﾄ",
            @"ﾅ",@"ﾆ",@"ﾇ",@"ﾈ",@"ﾉ",@"ﾊ",@"ﾋ",@"ﾌ",@"ﾍ",@"ﾎ",
            @"ﾏ",@"ﾐ",@"ﾑ",@"ﾒ",@"ﾓ",@"ﾔ",@"ﾕ",@"ﾖ",@"ﾗ",@"ﾘ",
            @"ﾙ",@"ﾚ",@"ﾛ",@"ﾜ",@"ﾝ",@"0",@"1",@"2",@"3",@"4",
            @"5",@"6",@"7",@"8",@"9",@"Z",@":",@".",@"=",@"*",
            @"+",@"-",@"<",@">"
        ];
        self.wantsLayer = YES;
        [self reloadPalette];
        [self rebuildGrid];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    if (_cols) free(_cols);
}

- (void)setAutoplay:(BOOL)autoplay {
    _autoplay = autoplay;
    [self syncTimer];
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    [self syncTimer];
}

- (void)syncTimer {
    BOOL run = _autoplay && !_paused;
    if (run) {
        if (!_timer) {
            _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 20.0
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        }
    } else {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self rebuildGrid];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self rebuildGrid];
}

- (uint32_t)parseHex:(NSString *)hex fallback:(uint32_t)fallback {
    if (hex.length < 6) return fallback;
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length < 6) return fallback;
    unsigned int value = 0;
    [[NSScanner scannerWithString:[clean substringToIndex:6]] scanHexInt:&value];
    return value;
}

- (void)reloadPalette {
    NSArray<NSString *> *paths = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/state/omacosy/matrix-rain.json"],
        [[NSBundle bundleForClass:[self class]] pathForResource:@"rain" ofType:@"json"] ?: @""
    ];
    for (NSString *path in paths) {
        if (path.length == 0) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) continue;
        _bg = [self parseHex:json[@"background"] fallback:_bg];
        _accent = [self parseHex:json[@"accent"] fallback:_accent];
        _head = [self parseHex:json[@"head"] fallback:_head];
        break;
    }
    _atlas = nil;
    [self buildAtlas];
    [self setNeedsDisplay:YES];
}

- (NSColor *)colorFromRGB:(uint32_t)rgb alpha:(CGFloat)alpha {
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xff) / 255.0
                                     green:((rgb >> 8) & 0xff) / 255.0
                                      blue:(rgb & 0xff) / 255.0
                                     alpha:alpha];
}

- (void)buildAtlas {
    NSMutableArray<NSImage *> *images = [NSMutableArray arrayWithCapacity:_glyphs.count];
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo-Bold"), _cellH * 0.82, NULL);
    if (!font) font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, _cellH * 0.82, NULL);
    for (NSString *ch in _glyphs) {
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(_cellW, _cellH)];
        [image lockFocus];
        [[NSColor clearColor] setFill];
        NSRectFill(NSMakeRect(0, 0, _cellW, _cellH));
        if (font) {
            NSColor *color = [NSColor whiteColor];
            CFAttributedStringRef attr = CFAttributedStringCreate(
                kCFAllocatorDefault,
                (__bridge CFStringRef)ch,
                (__bridge CFDictionaryRef)@{
                    (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
                    (__bridge NSString *)kCTForegroundColorAttributeName: (id)color.CGColor
                });
            CTLineRef line = CTLineCreateWithAttributedString(attr);
            CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
            CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
            CGContextSetTextPosition(ctx, 2, 4);
            CTLineDraw(line, ctx);
            CFRelease(line);
            CFRelease(attr);
        }
        [image unlockFocus];
        [images addObject:image];
    }
    if (font) CFRelease(font);
    _atlas = images;
}

- (void)rebuildGrid {
    NSSize size = self.bounds.size;
    if (size.width < 8 || size.height < 8) return;
    if (self.preview) {
        _cellW = 10;
        _cellH = 12;
    } else {
        _cellW = 18;
        _cellH = 22;
    }
    int cols = MAX(1, (int)floor(size.width / _cellW));
    int rows = MAX(1, (int)floor(size.height / _cellH));
    if (cols == _colCount && rows == _rowCount && _cols) return;

    if (_cols) free(_cols);
    _colCount = cols;
    _rowCount = rows;
    _cols = calloc((size_t)cols, sizeof(RainColumn));
    for (int i = 0; i < cols; i++) {
        [self resetColumn:i randomizeHead:YES];
    }
    _atlas = nil;
    [self buildAtlas];
}

- (void)resetColumn:(int)i randomizeHead:(BOOL)randomize {
    RainColumn *c = &_cols[i];
    c->speed = 0.16f + (float)(arc4random_uniform(180)) / 180.0f * 0.42f;
    c->length = 7 + (int)arc4random_uniform((uint32_t)MAX(4, _rowCount / 4));
    c->seed = (int)arc4random_uniform(100000);
    c->head = randomize ? (float)(arc4random_uniform((uint32_t)_rowCount)) : -((float)c->length);
}

- (void)tick {
    [self step];
    [self setNeedsDisplay:YES];
}

- (void)step {
    if (!_cols) return;
    for (int i = 0; i < _colCount; i++) {
        _cols[i].head += _cols[i].speed;
        if (_cols[i].head - _cols[i].length > _rowCount + 2) {
            [self resetColumn:i randomizeHead:NO];
        }
        if (arc4random_uniform(22) == 0) {
            _cols[i].seed += 1;
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;
    [[self colorFromRGB:_bg alpha:1] setFill];
    NSRectFill(bounds);
    if (!_cols || _atlas.count == 0) return;

    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    CGContextRef ctx = gc.CGContext;
    for (int x = 0; x < _colCount; x++) {
        RainColumn col = _cols[x];
        int headRow = (int)floorf(col.head);
        for (int d = 0; d < col.length; d++) {
            int y = headRow - d;
            if (y < 0 || y >= _rowCount) continue;
            float t = col.length <= 1 ? 1 : 1.0f - (float)d / (float)col.length;
            uint32_t rgb = (d == 0) ? _head : _accent;
            CGFloat alpha = (d == 0) ? 1.0 : (0.10 + t * 0.72);
            int glyphIndex = abs(col.seed * 131 + x * 17 + y * 29) % (int)_atlas.count;
            NSImage *glyph = _atlas[glyphIndex];
            NSRect dest = NSMakeRect(x * _cellW, bounds.size.height - (y + 1) * _cellH, _cellW, _cellH);
            CGContextSaveGState(ctx);
            [[self colorFromRGB:rgb alpha:alpha] set];
            NSRectFillUsingOperation(dest, NSCompositingOperationSourceOver);
            [glyph drawInRect:dest
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationDestinationIn
                     fraction:1.0];
            CGContextRestoreGState(ctx);
        }
    }
}

- (BOOL)isOpaque {
    return YES;
}

@end
