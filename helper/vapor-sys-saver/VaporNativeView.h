#import <MetalKit/MetalKit.h>

@interface VaporNativeView : MTKView <MTKViewDelegate>
@property (nonatomic, assign) BOOL preview;
- (void)start;
- (void)stop;
- (void)tick;
- (NSBitmapImageRep *)debugSnapshot;
@end
