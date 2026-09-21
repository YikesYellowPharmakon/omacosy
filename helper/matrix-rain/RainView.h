#import <Cocoa/Cocoa.h>

@interface RainView : NSView
@property (nonatomic, assign) BOOL autoplay;
@property (nonatomic, assign) BOOL preview;
- (void)reloadPalette;
- (void)step;
- (void)setPaused:(BOOL)paused;
@end
