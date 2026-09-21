#import <Cocoa/Cocoa.h>
#import "VaporNativeView.h"

static void countPixels(NSBitmapImageRep *rep, const char *label) {
    if (rep == nil) {
        fprintf(stderr, "%s: NIL snapshot\n", label);
        return;
    }
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    NSInteger black = 0, white = 0, other = 0;
    for (NSInteger y = 0; y < h; y += 8) {
        for (NSInteger x = 0; x < w; x += 8) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat r = c.redComponent, g = c.greenComponent, b = c.blueComponent;
            if (r < 0.08 && g < 0.08 && b < 0.08) black++;
            else if (r > 0.9 && g > 0.9 && b > 0.9) white++;
            else other++;
        }
    }
    fprintf(stderr, "%s size=%ldx%ld black=%ld white=%ld other=%ld\n",
            label, (long)w, (long)h, (long)black, (long)white, (long)other);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSRect frame = NSMakeRect(0, 0, 1280, 720);
        VaporNativeView *view = [[VaporNativeView alloc] initWithFrame:frame];
        NSBitmapImageRep *initRep = [view debugSnapshot];
        countPixels(initRep, "init");
        NSString *outInit = @"/Users/ye/Projects/mac-theme/.theme-imports/vapor-sys-saver/proof-init.png";
        [[initRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:outInit atomically:YES];

        [view start];
        for (int i = 0; i < 36; i++) {
            [view tick];
        }
        NSBitmapImageRep *runRep = [view debugSnapshot];
        countPixels(runRep, "after-36-ticks");
        NSString *outRun = argc > 1 ? @(argv[1]) : @"/Users/ye/Projects/mac-theme/.theme-imports/vapor-sys-saver/proof-run.png";
        [[runRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:outRun atomically:YES];
    }
    return 0;
}
