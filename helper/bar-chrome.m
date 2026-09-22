// Hides the omacosy bar while a browser is fullscreen.
//
// Chrome's fullscreen page starts below the toolbar (measured y=122 on the
// built-in), so the bar at level -20 shows through that band, and a pointer
// at the top edge climbs it to level 1002. bar.swift now detects that page,
// but this machine's Swift compiler cannot rebuild the bar. This process
// sets the bar window's alpha to 0 for the same geometry and puts it back
// when the page goes away. It does not loosen the full-width test.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef int SLSConnectionID;
extern SLSConnectionID SLSMainConnectionID(void);
extern CGError SLSSetWindowAlpha(SLSConnectionID cid, uint32_t wid, float alpha);

static SLSConnectionID cid;
static NSMutableDictionary<NSNumber *, NSNumber *> *applied;
static BOOL checkOnly = NO;

static void logLine(NSString *line) {
    FILE *f = fopen("/tmp/omacosy-bar-chrome.log", "a");
    if (!f) return;
    fprintf(f, "%s\n", line.UTF8String);
    fclose(f);
}

static BOOL browserOwner(NSString *name) {
    if ([name hasPrefix:@"Google Chrome"]) return YES;
    for (NSString *known in @[@"Chromium", @"Arc", @"Microsoft Edge", @"Brave Browser", @"Dia"]) {
        if ([name isEqualToString:known]) return YES;
    }
    return NO;
}

static CGRect windowRect(NSDictionary *window) {
    NSDictionary *b = window[(id)kCGWindowBounds];
    return CGRectMake([b[@"X"] doubleValue], [b[@"Y"] doubleValue],
                      [b[@"Width"] doubleValue], [b[@"Height"] doubleValue]);
}

static BOOL chromePage(CGRect rect, CGRect display) {
    if (!CGRectIntersectsRect(display, rect)) return NO;
    CGFloat top = rect.origin.y - display.origin.y;
    CGFloat bottom = (display.origin.y + display.size.height) - CGRectGetMaxY(rect);
    BOOL fullWidth = rect.size.width >= display.size.width - 2
        && fabs(CGRectGetMinX(rect) - CGRectGetMinX(display)) < 4;
    return fullWidth && top < 240 && bottom < 20
        && rect.size.height >= MAX(400.0, display.size.height * 0.68);
}

static NSSet<NSNumber *> *browserFullscreenDisplays(void) {
    uint32_t ids[8] = {0};
    uint32_t count = 0;
    if (CGGetActiveDisplayList(8, ids, &count) != kCGErrorSuccess) return [NSSet set];
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSMutableSet *covered = [NSMutableSet set];
    for (NSDictionary *window in (__bridge NSArray *)info) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        if (!browserOwner(window[(id)kCGWindowOwnerName] ?: @"")) continue;
        CGRect rect = windowRect(window);
        for (uint32_t i = 0; i < count; i++) {
            if (chromePage(rect, CGDisplayBounds(ids[i]))) [covered addObject:@(ids[i])];
        }
    }
    if (info) CFRelease(info);
    return covered;
}

static uint32_t displayContaining(CGRect rect, uint32_t *ids, uint32_t count) {
    CGPoint mid = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    for (uint32_t i = 0; i < count; i++) {
        if (CGRectContainsPoint(CGDisplayBounds(ids[i]), mid)) return ids[i];
    }
    return 0;
}

static void apply(void) {
    NSSet<NSNumber *> *covered = browserFullscreenDisplays();
    uint32_t ids[8] = {0};
    uint32_t count = 0;
    CGGetActiveDisplayList(8, ids, &count);
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    for (NSDictionary *window in (__bridge NSArray *)info) {
        NSString *owner = window[(id)kCGWindowOwnerName] ?: @"";
        if (![owner isEqualToString:@"omacosy-bar"]) continue;
        uint32_t wid = [window[(id)kCGWindowNumber] unsignedIntValue];
        CGRect rect = windowRect(window);
        uint32_t display = displayContaining(rect, ids, count);
        float want = [covered containsObject:@(display)] ? 0.f : 1.f;
        NSNumber *key = @(wid);
        if (checkOnly) {
            printf("bar wid=%u display=%u alpha=%g -> %g bounds=%.0f,%.0f %.0fx%.0f covered=%s\n",
                   wid, display, [window[(id)kCGWindowAlpha] doubleValue], want,
                   rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                   want == 0 ? "yes" : "no");
            continue;
        }
        // Keep forcing 0: the bar re-orders itself on pointer moves and
        // would otherwise climb back over Chrome's toolbar.
        if (want == 1.f && applied[key] && applied[key].floatValue == 1.f) continue;
        BOOL changed = applied[key] == nil || applied[key].floatValue != want;
        CGError err = SLSSetWindowAlpha(cid, wid, want);
        applied[key] = @(want);
        if (changed || err != kCGErrorSuccess) {
            logLine([NSString stringWithFormat:@"wid=%u want=%.0f err=%d", wid, want, err]);
        }
    }
    if (info) CFRelease(info);
    if (checkOnly) {
        printf("browser-fullscreen displays:");
        for (NSNumber *d in covered) printf(" %u", d.unsignedIntValue);
        printf("\n");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        checkOnly = argc > 1 && strcmp(argv[1], "--check") == 0;
        cid = SLSMainConnectionID();
        applied = [NSMutableDictionary dictionary];
        if (checkOnly) {
            apply();
            return 0;
        }
        logLine(@"watch start");
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *t) {
            apply();
        }];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
