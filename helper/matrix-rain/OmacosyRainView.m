#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "MatrixRain.h"

@interface OmacosyRainView : ScreenSaverView
@property (nonatomic, strong) MatrixRainView *rain;
@end

@implementation OmacosyRainView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1.0 / 30.0];
        self.rain = [[MatrixRainView alloc] initWithFrame:self.bounds];
        self.rain.wordmark = YES;
        self.rain.calm = NO;
        self.rain.preferredFramesPerSecond = 30;
        self.rain.cellHeight = 16.f;
        self.rain.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        if (isPreview)
            self.rain.layer.magnificationFilter = kCAFilterLinear;
        [self addSubview:self.rain];
    }
    return self;
}

- (void)startAnimation {
    [super startAnimation];
    self.rain.cellHeight = 16.f;
    [self.rain syncDrawableToScreen];
    [self.rain restart];
    self.rain.paused = NO;
}

- (void)stopAnimation {
    [super stopAnimation];
    self.rain.paused = YES;
}

- (void)animateOneFrame {
}

- (BOOL)hasConfigureSheet {
    return NO;
}

@end
