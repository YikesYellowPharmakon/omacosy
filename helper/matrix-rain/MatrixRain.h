#import <MetalKit/MetalKit.h>

@interface MatrixRainView : MTKView <MTKViewDelegate>
@property (nonatomic, assign) BOOL wordmark;
@property (nonatomic, assign) BOOL calm;
@property (nonatomic, assign) float cellHeight;
- (void)restart;
- (void)setClock:(float)elapsed birth:(float)birth;
- (void)syncDrawableToScreen;
+ (BOOL)writeSnapshotToURL:(NSURL *)url size:(CGSize)size wordmark:(BOOL)wordmark;
@end
