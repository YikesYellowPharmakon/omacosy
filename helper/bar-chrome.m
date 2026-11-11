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

// The gap is not watched while windows sit still. A retune runs once,
// two seconds after launch, wake, or a display change, and only when a
// tiled window is more than 8 points away from y=41.
static int epochShots = 0;
static int epochDisplays = -1;
static CFAbsoluteTime quietUntil = 0;

static void syncMainTopGap(void);
static BOOL gapRetuneOnce = NO;
static int retuneToken = 0;

static void scheduleGapRetune(void) {
    int token = ++retuneToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != retuneToken) return;
        epochShots = 0;
        quietUntil = 0;
        gapRetuneOnce = YES;
        syncMainTopGap();
        gapRetuneOnce = NO;
    });
}

// Floating windows sit wherever they were dropped. Option-T toggles
// them back to tiling, and their in-between tops must not move the gap
// or the tiled layout walks down to y=41 in several reloads.
static BOOL widIsTiled(uint32_t wid) {
    if (!wid) return NO;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin/aerospace"];
    task.arguments = @[@"list-windows", @"--all", @"--format", @"%{window-id} %{window-layout}"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    // Nobody reads stderr, so it goes nowhere rather than into a pipe that
    // would stop the child once 64 KB had piled up in it.
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return YES;
    // Read to the end BEFORE waiting. Waiting first never returns once the
    // window list outgrows the pipe: the child blocks writing, and this
    // blocks on the child.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return YES;
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *prefix = [NSString stringWithFormat:@"%u ", wid];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:prefix]) continue;
        return [line rangeOfString:@"tile"].location != NSNotFound;
    }
    return NO;
}

// Built-in tiled windows must start at y=41, just under the 34pt bar.
// AeroSpace adds a 30pt menu-bar reservation in some layouts and not
// others, so monitor.main is either 11 or 41. This picks that once.
static void syncMainTopGap(void) {
    static CFAbsoluteTime stableSince = 0;
    static CGFloat stableY = -1;
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
    if ((int)displayCount != epochDisplays) {
        epochDisplays = (int)displayCount;
        epochShots = 0;
    }

    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    CGFloat windowY = CGFLOAT_MAX;
    uint32_t measuredWid = 0;
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
        if (rect.origin.y < windowY) {
            windowY = rect.origin.y;
            measuredWid = [window[(id)kCGWindowNumber] unsignedIntValue];
        }
    }
    if (info) CFRelease(info);
    if (windowY > 400) return;
    if (!gapRetuneOnce) {
        if (stableY < 0 || fabs(windowY - stableY) > 2) {
            stableY = windowY;
            stableSince = CFAbsoluteTimeGetCurrent();
            return;
        }
        if (CFAbsoluteTimeGetCurrent() - stableSince < 1.2) return;
    }
    // A few points of jitter is a stationary window. Rewriting the gap
    // for that is what moves it on its own.
    if (fabs(windowY - 41) <= 8) return;
    if (!widIsTiled(measuredWid)) return;

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/aerospace/aerospace.toml"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"monitor\\.main = (\\d+)" options:0 error:nil];
    NSTextCheckingResult *hit = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!hit || hit.numberOfRanges < 2) return;
    int gap = [[text substringWithRange:[hit rangeAtIndex:1]] intValue];
    // 71 means the 30pt reservation is on and the running gap is still 41.
    // 30 or 11 means that reservation is off and the gap is inside the bar.
    // Anything nearer than that is left alone, so a still window does not move.
    int next = -1;
    if (fabs(windowY - 71) <= 8) next = 11;
    else if (fabs(windowY - 30) <= 2 || fabs(windowY - 11) <= 2) next = 41;
    else return;
    static CGFloat latchedY = -1;
    if (latchedY >= 0 && fabs(windowY - latchedY) < 15) return;
    if (next != gap) {
        NSString *updated = [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                                     withTemplate:[NSString stringWithFormat:@"monitor.main = %d", next]];
        if (![updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    }
    NSTask *reload = [NSTask new];
    reload.executableURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin/aerospace"];
    reload.arguments = @[@"reload-config"];
    [reload launchAndReturnError:nil];
    latchedY = windowY;
    quietUntil = CFAbsoluteTimeGetCurrent() + 30.0;
    stableY = -1;
    logLine([NSString stringWithFormat:@"main top reload %d -> %d (window y %.0f)", gap, next, windowY]);
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

// The bar orders a surface out while a fullscreen window covers its
// display and orders it back in on the next window event. After Chrome
// fullscreen that order-in can silently do nothing: the process stays
// up, the window keeps alpha 1, and it is never listed on screen again.
// Only the bar's own connection may order its windows (SLSOrderWindow
// from here returns 1000), so the repair is a restart of the bar.
// It runs only when a display has had no bar for several seconds while
// nothing on it should hide the bar.
static const int kMissingGraceSeconds = 4;
static NSMutableDictionary<NSNumber *, NSNumber *> *missingSince;
static NSMutableArray<NSDate *> *barKicks;
static BOOL sessionLocked = NO;
static CFAbsoluteTime unlockedAt = 0;

static BOOL screenIsLocked(void) {
    if (sessionLocked) return YES;
    if (CFAbsoluteTimeGetCurrent() - unlockedAt < 5) return YES;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return YES;
    NSDictionary *d = (__bridge NSDictionary *)session;
    BOOL locked = [d[@"CGSSessionScreenIsLocked"] boolValue] || ![d[(id)kCGSessionOnConsoleKey] boolValue];
    CFRelease(session);
    return locked;
}

static BOOL systemSpreadUp(NSArray *windows) {
    for (NSDictionary *window in windows) {
        NSString *owner = window[(id)kCGWindowOwnerName] ?: @"";
        if (![owner isEqualToString:@"Dock"] && ![owner isEqualToString:@"WindowManager"]) continue;
        CGRect rect = windowRect(window);
        if (rect.size.width < 160 || rect.size.height < 160) continue;
        if ([owner isEqualToString:@"WindowManager"] && [window[(id)kCGWindowLayer] intValue] < 0) continue;
        return YES;
    }
    return NO;
}

static NSScreen *screenForDisplay(CGDirectDisplayID display) {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *n = screen.deviceDescription[@"NSScreenNumber"];
        if (n.unsignedIntValue == display) return screen;
    }
    return nil;
}

// The bar only draws on displays AeroSpace lists by name. A display it
// does not list has no bar on purpose, and a restart would not add one.
static BOOL aerospaceListsScreen(NSScreen *screen) {
    if (!screen) return NO;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin/aerospace"];
    task.arguments = @[@"list-monitors", @"--format", @"%{monitor-name}"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return NO;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return NO;
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line isEqualToString:screen.localizedName]) return YES;
    }
    return NO;
}

// Same test as fullscreenDisplays() in bar.swift: a flush full-width
// window, or a browser page under its fullscreen toolbar.
static BOOL displayCoveredByFullscreen(CGRect display, NSScreen *screen, NSArray *windows) {
    CGFloat inset = screen ? screen.safeAreaInsets.top : 0;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect rect = windowRect(window);
        if (rect.size.width < 1 || rect.size.height < 1) continue;
        if (!CGRectIntersectsRect(display, rect)) continue;
        CGFloat top = rect.origin.y - display.origin.y;
        BOOL fullWidth = rect.size.width >= display.size.width - 2
            && fabs(CGRectGetMinX(rect) - CGRectGetMinX(display)) < 4;
        BOOL flush = top < inset + 3 && rect.size.height >= display.size.height - inset - 6 && fullWidth;
        if (flush || chromePage(rect, display)) return YES;
    }
    return NO;
}

static BOOL barShownOnDisplay(CGRect display, NSArray *windows) {
    for (NSDictionary *window in windows) {
        if (![window[(id)kCGWindowOwnerName] isEqualToString:@"omacosy-bar"]) continue;
        if ([window[(id)kCGWindowAlpha] doubleValue] < 0.05) continue;
        CGRect rect = windowRect(window);
        if (rect.size.height > 80) continue;
        if (!CGRectContainsPoint(display, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)))) continue;
        if (rect.origin.y - display.origin.y > 40) continue;
        return YES;
    }
    return NO;
}

static BOOL mayKickBar(void) {
    NSDate *now = [NSDate date];
    NSMutableArray *recent = [NSMutableArray array];
    for (NSDate *at in barKicks) {
        if ([now timeIntervalSinceDate:at] < 600) [recent addObject:at];
    }
    barKicks = recent;
    if (recent.count >= 3) return NO;
    NSDate *last = recent.lastObject;
    return !last || [now timeIntervalSinceDate:last] >= 20;
}

static void kickBar(NSString *why) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"kickstart", @"-k", [NSString stringWithFormat:@"gui/%u/com.omacosy.bar", getuid()]];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return;
    [task waitUntilExit];
    [barKicks addObject:[NSDate date]];
    [applied removeAllObjects];
    [missingSince removeAllObjects];
    logLine([NSString stringWithFormat:@"bar restart (%@) rc=%d", why, task.terminationStatus]);
}

static void watchBarPresence(void) {
    if (exposeHeld() || screenIsLocked()) {
        [missingSince removeAllObjects];
        return;
    }
    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    CFArrayRef shown = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSArray *allWindows = all ? (__bridge_transfer NSArray *)all : @[];
    NSArray *onScreen = shown ? (__bridge_transfer NSArray *)shown : @[];
    BOOL barAlive = NO;
    for (NSDictionary *window in allWindows) {
        if ([window[(id)kCGWindowOwnerName] isEqualToString:@"omacosy-bar"]) { barAlive = YES; break; }
    }
    // No bar windows at all is launchd's job (KeepAlive); an empty
    // on-screen list is a failed read, not a missing bar.
    if (!barAlive || onScreen.count == 0 || systemSpreadUp(onScreen)) {
        [missingSince removeAllObjects];
        return;
    }
    uint32_t ids[8] = {0};
    uint32_t count = 0;
    if (CGGetActiveDisplayList(8, ids, &count) != kCGErrorSuccess) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableSet *seen = [NSMutableSet set];
    CGDirectDisplayID overdue = 0;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = ids[i];
        NSNumber *key = @(display);
        [seen addObject:key];
        CGRect bounds = CGDisplayBounds(display);
        NSScreen *screen = screenForDisplay(display);
        if (CGDisplayIsAsleep(display) || !screen
            || barShownOnDisplay(bounds, onScreen)
            || displayCoveredByFullscreen(bounds, screen, onScreen)) {
            [missingSince removeObjectForKey:key];
            continue;
        }
        if (!missingSince[key]) {
            missingSince[key] = @(now);
            continue;
        }
        if (now - missingSince[key].doubleValue >= kMissingGraceSeconds && !overdue) overdue = display;
    }
    for (NSNumber *key in missingSince.allKeys) {
        if (![seen containsObject:key]) [missingSince removeObjectForKey:key];
    }
    if (!overdue) return;
    NSScreen *screen = screenForDisplay(overdue);
    if (!mayKickBar()) return;
    if (!aerospaceListsScreen(screen)) {
        missingSince[@(overdue)] = @(now);
        return;
    }
    kickBar([NSString stringWithFormat:@"no bar on %@ for %ds", screen.localizedName, kMissingGraceSeconds]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        checkOnly = argc > 1 && strcmp(argv[1], "--check") == 0;
        cid = SLSMainConnectionID();
        applied = [NSMutableDictionary dictionary];
        [NSApplication sharedApplication];
        if (checkOnly) {
            apply();
            CFArrayRef shown = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
            NSArray *onScreen = shown ? (__bridge_transfer NSArray *)shown : @[];
            printf("watch: locked=%d expose=%d spread=%d\n",
                   screenIsLocked(), exposeHeld(), systemSpreadUp(onScreen));
            uint32_t ids[8] = {0};
            uint32_t count = 0;
            CGGetActiveDisplayList(8, ids, &count);
            for (uint32_t i = 0; i < count; i++) {
                CGRect bounds = CGDisplayBounds(ids[i]);
                NSScreen *screen = screenForDisplay(ids[i]);
                printf("watch: display=%u %s asleep=%d bar=%d fullscreen=%d listed=%d\n", ids[i],
                       screen.localizedName.UTF8String ?: "?", CGDisplayIsAsleep(ids[i]),
                       barShownOnDisplay(bounds, onScreen), displayCoveredByFullscreen(bounds, screen, onScreen),
                       aerospaceListsScreen(screen));
            }
            return 0;
        }
        logLine(@"watch start");
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidWakeNotification
                                                                        object:nil queue:nil
                                                                    usingBlock:^(__unused NSNotification *note) {
            unlockedAt = CFAbsoluteTimeGetCurrent();
            scheduleGapRetune();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(__unused NSNotification *note) {
            scheduleGapRetune();
        }];
        scheduleGapRetune();
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *t) {
            syncMainTopGap();
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *t) {
            apply();
        }];
        missingSince = [NSMutableDictionary dictionary];
        barKicks = [NSMutableArray array];
        NSDistributedNotificationCenter *dnc = NSDistributedNotificationCenter.defaultCenter;
        [dnc addObserverForName:@"com.apple.screenIsLocked" object:nil queue:nil
                     usingBlock:^(__unused NSNotification *note) {
            sessionLocked = YES;
        }];
        [dnc addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:nil
                     usingBlock:^(__unused NSNotification *note) {
            sessionLocked = NO;
            unlockedAt = CFAbsoluteTimeGetCurrent();
        }];
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
            watchBarPresence();
        }];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
