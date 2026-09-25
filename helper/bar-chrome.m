// Hides the omacosy bar while a browser is fullscreen.
//
// Chrome's fullscreen page starts below the toolbar (measured y=122 on the
// built-in), so the bar at level -20 shows through that band, and a pointer
// at the top edge climbs it to level 1002. bar.swift now detects that page,
// but this machine's Swift compiler cannot rebuild the bar. This process
// sets the bar window's alpha to 0 for the same geometry and puts it back
// when the page goes away. It does not loosen the full-width test.

#import <AppKit/AppKit.h>
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

static BOOL exposeHeld(void) {
    NSString *text = [NSString stringWithContentsOfFile:@"/tmp/omacosy-expose" encoding:NSUTF8StringEncoding error:nil];
    return [text containsString:@"1"];
}

// Built-in window top must stay at y=41, just under the 34pt bar.
// AeroSpace sometimes adds the menu-bar reservation and sometimes does
// not, so a fixed monitor.main is wrong in one of the two layouts.
// Only a settled tiled window counts. A fullscreen page (Chrome sits
// near y=122) and the frames while it animates back must not move the
// gap, or reload-config walks the window down in visible steps.
static void syncMainTopGap(void) {
    static CFAbsoluteTime quietUntil = 0;
    static CFAbsoluteTime stableSince = 0;
    static CGFloat stableY = -1;
    static CGFloat lastCorrectedY = -1;
    if (CFAbsoluteTimeGetCurrent() < quietUntil) return;
    if (browserFullscreenDisplays().count > 0) {
        stableY = -1;
        return;
    }
    CGRect builtIn = CGRectNull;
    uint32_t displayCount = 0;
    CGDirectDisplayID displays[8];
    if (CGGetActiveDisplayList(8, displays, &displayCount) != kCGErrorSuccess || displayCount < 1) return;
    for (uint32_t i = 0; i < displayCount; i++) {
        CGRect bounds = CGDisplayBounds(displays[i]);
        if (fabs(bounds.origin.x) < 1 && fabs(bounds.origin.y) < 1) builtIn = bounds;
    }
    if (CGRectIsNull(builtIn)) return;

    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    CGFloat windowY = CGFLOAT_MAX;
    for (NSDictionary *window in (__bridge NSArray *)info) {
        if ([window[(id)kCGWindowLayer] integerValue] != 0) continue;
        NSString *owner = window[(id)kCGWindowOwnerName];
        if ([owner isEqualToString:@"omacosy-bar"] || [owner isEqualToString:@"omacosy-borders"] ||
            [owner isEqualToString:@"Dock"] || [owner isEqualToString:@"Window Server"]) continue;
        CGRect rect = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)window[(id)kCGWindowBounds], &rect);
        if (rect.size.width < 400 || rect.size.height < 400) continue;
        if (rect.size.height > builtIn.size.height - 4) continue;
        // Chrome's fullscreen page sits near y=122. Other windows, including
        // one left at y=150 after a bad gap, still need a correction.
        if (rect.origin.y > 80 && browserOwner(owner)) continue;
        if (!CGRectContainsPoint(builtIn, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)))) continue;
        if (rect.origin.y < windowY) windowY = rect.origin.y;
    }
    if (info) CFRelease(info);
    if (windowY > 400) {
        stableY = -1;
        return;
    }
    if (stableY < 0 || fabs(windowY - stableY) > 2) {
        stableY = windowY;
        stableSince = CFAbsoluteTimeGetCurrent();
        return;
    }
    if (CFAbsoluteTimeGetCurrent() - stableSince < 0.6) return;
    if (fabs(windowY - 41) <= 2) return;

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/aerospace/aerospace.toml"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"monitor\\.main = (\\d+)" options:0 error:nil];
    NSTextCheckingResult *hit = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!hit || hit.numberOfRanges < 2) return;
    int gap = [[text substringWithRange:[hit rangeAtIndex:1]] intValue];
    // y=30 is AeroSpace's clamp, not a real top. Adding 11 while it stays
    // there walks the gap to the cap and shoves the window down the screen.
    if (lastCorrectedY >= 0 && fabs(windowY - lastCorrectedY) <= 2) return;
    int next = gap - (int)llround(windowY - 41);
    if (fabs(windowY - 30) <= 1) next = 41;
    if (next < 0) next = 0;
    if (next > 46) next = 46;
    if (next == gap) return;
    NSString *updated = [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                                 withTemplate:[NSString stringWithFormat:@"monitor.main = %d", next]];
    if (![updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    NSTask *reload = [NSTask new];
    reload.executableURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin/aerospace"];
    reload.arguments = @[@"reload-config"];
    [reload launchAndReturnError:nil];
    quietUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    stableY = -1;
    lastCorrectedY = windowY;
    logLine([NSString stringWithFormat:@"main top gap %d -> %d (window y %.0f)", gap, next, windowY]);
}

static void apply(void) {
    if (exposeHeld()) {
        CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
        for (NSDictionary *window in (__bridge NSArray *)info) {
            if (![window[(id)kCGWindowOwnerName] isEqualToString:@"omacosy-bar"]) continue;
            uint32_t wid = [window[(id)kCGWindowNumber] unsignedIntValue];
            if (!wid) continue;
            SLSSetWindowAlpha(cid, wid, 0);
            applied[@(wid)] = @0;
        }
        if (info) CFRelease(info);
        return;
    }
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
        [NSApplication sharedApplication];
        if (checkOnly) {
            apply();
            return 0;
        }
        logLine(@"watch start");
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *t) {
            syncMainTopGap();
            apply();
        }];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
