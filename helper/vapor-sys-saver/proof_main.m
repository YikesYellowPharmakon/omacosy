#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>

@interface OmacosyVaporView : ScreenSaverView
- (BOOL)writeProofTo:(NSString *)path;
- (void)stepWithDt:(float)dt;
@end

int main(void) {
    @autoreleasepool {
        OmacosyVaporView *view = [[OmacosyVaporView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360) isPreview:YES];
        for (int i = 0; i < 20; i++) {
            [view stepWithDt:0.05f];
        }
        NSString *out = @"/Users/ye/Projects/mac-theme/.theme-imports/vapor-sys-saver/proof-settings.png";
        BOOL ok = [view writeProofTo:out];
        fprintf(stderr, "proof %s ok=%d\n", out.UTF8String, ok);
        return ok ? 0 : 1;
    }
}
