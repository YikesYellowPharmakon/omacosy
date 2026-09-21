#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import "VaporNativeView.h"

@interface OmacosyVaporView : ScreenSaverView
@property (nonatomic, strong) VaporNativeView *native;
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSRect frame = NSMakeRect(0, 0, 1280, 720);
        OmacosyVaporView *saver = [[OmacosyVaporView alloc] initWithFrame:frame isPreview:YES];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        window.backgroundColor = [NSColor magentaColor];
        window.title = @"OmacosyVapor host";
        window.contentView = saver;
        [window makeKeyAndOrderFront:nil];
        [saver startAnimation];
        for (int i = 0; i < 20; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        NSBitmapImageRep *rep = [saver.native debugSnapshot];
        NSString *out = @"/Users/ye/Projects/mac-theme/.theme-imports/vapor-sys-saver/proof-host.png";
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        fprintf(stderr, "host snapshot %s native=%p size=%.0fx%.0f\n",
                out.UTF8String, saver.native, saver.bounds.size.width, saver.bounds.size.height);
        if (argc > 1 && strcmp(argv[1], "--stay") == 0) {
            [NSApp run];
        }
    }
    return 0;
}
