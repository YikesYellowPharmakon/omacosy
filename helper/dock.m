// Bottom dock in the top bar's palette. Nothing is reserved: aerospace
// keeps outer.bottom at 2, and this capsule only exists while the pointer
// is on the screen edge. Clicks go through a nonactivating panel so the
// target app comes forward without this process taking the click first.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

typedef int SLSConnectionID;
extern SLSConnectionID SLSMainConnectionID(void);
extern CGError SLSSetWindowAlpha(SLSConnectionID cid, uint32_t wid, float alpha);

static const CGFloat kIcon = 32;
static const CGFloat kPadX = 10;
static const CGFloat kPadY = 6;
static const CGFloat kGap = 6;
static const CGFloat kSplit = 14;
static const CGFloat kRadius = 4;
static const CGFloat kLift = 6;
static const CGFloat kDragHeadroom = 18;
static const NSInteger kDockLevel = 1002;
static const NSInteger kStripLevel = 1001;
// The system Dock's fullscreen reveal starts when the pointer is on the
// bottom two points. The hit strip is taller than that, and the pointer
// is held on the inner part of the strip.
static const CGFloat kStripHeight = 8;
static const CGFloat kEdgeGuard = 4;

static void note(const char *msg) {
    fprintf(stderr, "omacosy-dock: %s\n", msg);
}

static BOOL zh(void) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
}

static NSString *normPath(NSString *path) {
    if (path.length > 1 && [path hasSuffix:@"/"]) return [path substringToIndex:path.length - 1];
    return path ?: @"";
}

static NSColor *colorFromARGB(unsigned long v) {
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xff) / 255.0
                               green:((v >> 8) & 0xff) / 255.0
                                blue:(v & 0xff) / 255.0
                               alpha:((v >> 24) & 0xff) / 255.0];
}

static BOOL appHasVisibleWindow(pid_t pid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;
    BOOL found = NO;
    for (NSDictionary *window in (__bridge NSArray *)list) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if ([window[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([window[(id)kCGWindowAlpha] doubleValue] < 0.05) continue;
        NSDictionary *bounds = window[(id)kCGWindowBounds];
        if ([bounds[@"Width"] doubleValue] < 40 || [bounds[@"Height"] doubleValue] < 40) continue;
        found = YES;
        break;
    }
    CFRelease(list);
    return found;
}

// Dock's own click, when the app is running but has no window: ask it to
// open one. kAENoReply so this returns without waiting on the app.
static void reopenApp(pid_t pid) {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
                                                                             eventID:kAEReopenApplication
                                                                    targetDescriptor:target
                                                                            returnID:kAutoGenerateReturnID
                                                                       transactionID:kAnyTransactionID];
    AESendMessage(event.aeDesc, NULL, kAENoReply | kAENeverInteract, kAEDefaultTimeout);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static LSSharedFileListRef loginList(void) {
    return LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
}

static BOOL loginItemEnabled(NSURL *url) {
    LSSharedFileListRef list = loginList();
    if (!list) return NO;
    NSString *want = normPath(url.path);
    UInt32 seed = 0;
    NSArray *items = (__bridge_transfer NSArray *)LSSharedFileListCopySnapshot(list, &seed);
    BOOL found = NO;
    for (id item in items) {
        CFURLRef resolved = NULL;
        if (LSSharedFileListItemResolve((__bridge LSSharedFileListItemRef)item, 0, &resolved, NULL) != noErr || !resolved) continue;
        NSString *path = normPath([(__bridge NSURL *)resolved path]);
        CFRelease(resolved);
        if ([path isEqualToString:want]) { found = YES; break; }
    }
    CFRelease(list);
    return found;
}

static void setLoginItem(NSURL *url, BOOL on) {
    LSSharedFileListRef list = loginList();
    if (!list) return;
    NSString *want = normPath(url.path);
    if (on) {
        LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)url, NULL, NULL);
    } else {
        UInt32 seed = 0;
        NSArray *items = (__bridge_transfer NSArray *)LSSharedFileListCopySnapshot(list, &seed);
        for (id item in items) {
            CFURLRef resolved = NULL;
            if (LSSharedFileListItemResolve((__bridge LSSharedFileListItemRef)item, 0, &resolved, NULL) != noErr || !resolved) continue;
            BOOL match = [normPath([(__bridge NSURL *)resolved path]) isEqualToString:want];
            CFRelease(resolved);
            if (match) LSSharedFileListItemRemove(list, (__bridge LSSharedFileListItemRef)item);
        }
    }
    CFRelease(list);
}

#pragma clang diagnostic pop

@interface DockTile : NSObject
@property(strong) NSURL *url;
@property(strong) NSImage *icon;
@property(copy) NSString *bundleID;
@property(copy) NSString *name;
@property(assign) NSRect rect;
@property(assign) NSRect hit;
@property(assign) BOOL running;
@property(assign) BOOL focused;
@property(assign) BOOL pinned;
@end
@implementation DockTile
@end

@interface DockController : NSObject <NSMenuDelegate>
- (void)start;
- (void)showTest;
- (void)showOnScreen:(NSScreen *)screen;
- (void)pointerEnteredCapsule;
- (void)pointerLeft;
- (void)openTile:(DockTile *)tile;
- (NSMenu *)menuForTile:(DockTile *)tile;
- (void)beginReorder:(DockTile *)tile;
- (void)reorderTile:(DockTile *)tile toViewPoint:(NSPoint)point;
- (void)endReorder;
@property(nonatomic) BOOL menuOpen;
@property(nonatomic) BOOL dragging;
@end

static DockController *controller;

@interface EdgePanel : NSPanel
@property(nonatomic) BOOL allowingKey;
@end
@implementation EdgePanel
- (BOOL)canBecomeKeyWindow { return self.allowingKey; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }
@end

@interface EdgeWindow : NSWindow
@end
@implementation EdgeWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }
@end

@interface HitView : NSView
@end
@interface CapsuleView : NSView
@property(strong) NSArray<DockTile *> *tiles;
@property(assign) CGFloat splitX;
@property(assign) BOOL hasSplit;
@property(strong) NSColor *fill;
@property(strong) NSColor *accent;
@property(strong) NSColor *muted;
@property(weak) DockTile *dragTile;
- (DockTile *)tileAt:(NSPoint)point;
@end

@implementation HitView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { [controller showOnScreen:self.window.screen]; }
- (void)mouseExited:(NSEvent *)event { [controller pointerLeft]; }
@end

@implementation CapsuleView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (DockTile *)tileAt:(NSPoint)point {
    for (DockTile *tile in self.tiles) {
        if (NSPointInRect(point, tile.hit)) return tile;
    }
    return nil;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { [controller pointerEnteredCapsule]; }
- (void)mouseExited:(NSEvent *)event { [controller pointerLeft]; }
- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self rightMouseDown:event];
        return;
    }
    NSPoint start = [self convertPoint:event.locationInWindow fromView:nil];
    DockTile *tile = [self tileAt:start];
    if (!tile) return;
    BOOL dragging = NO;
    while (YES) {
        @autoreleasepool {
            NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
            if (!next || next.type == NSEventTypeLeftMouseUp) break;
            NSPoint p = [self convertPoint:next.locationInWindow fromView:nil];
            if (!dragging && hypot(p.x - start.x, p.y - start.y) >= 6) {
                dragging = YES;
                [controller beginReorder:tile];
            }
            if (dragging) [controller reorderTile:tile toViewPoint:p];
        }
    }
    if (dragging) [controller endReorder];
    else [controller openTile:tile];
}
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    DockTile *tile = [self tileAt:p];
    if (!tile) return;
    controller.menuOpen = YES;
    [controller pointerEnteredCapsule];
    NSMenu *menu = [controller menuForTile:tile];
    EdgePanel *panel = (EdgePanel *)self.window;
    panel.allowingKey = YES;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    panel.allowingKey = NO;
    controller.menuOpen = NO;
    [controller pointerLeft];
}
- (void)drawRect:(NSRect)dirty {
    if (self.tiles.count == 0) return;
    CGFloat head = self.dragTile ? kDragHeadroom : 0;
    NSRect pill = NSMakeRect(0, kLift, self.bounds.size.width, self.bounds.size.height - kLift - head);
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, 0.5, 0.5)
                                                         xRadius:kRadius yRadius:kRadius];
    [self.fill setFill];
    [body fill];
    if (self.hasSplit) {
        [[self.muted colorWithAlphaComponent:0.55] setFill];
        NSRectFill(NSMakeRect(self.splitX, NSMidY(pill) - 8, 1, 16));
    }
    DockTile *lifted = nil;
    for (DockTile *tile in self.tiles) {
        if (tile == self.dragTile) { lifted = tile; continue; }
        [self drawTile:tile lifted:NO];
    }
    if (lifted) [self drawTile:lifted lifted:YES];
}
- (void)drawTile:(DockTile *)tile lifted:(BOOL)lifted {
    NSRect rect = lifted ? NSOffsetRect(tile.rect, 0, kDragHeadroom) : tile.rect;
    if (tile.focused || lifted) {
        [[self.accent colorWithAlphaComponent:lifted ? 0.4 : 0.28] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, -3, -3)
                                        xRadius:kRadius yRadius:kRadius] fill];
    }
    [tile.icon drawInRect:rect];
    if (tile.running) {
        NSRect mark = NSMakeRect(NSMidX(rect) - 2, NSMinY(rect) - 5, 4, 3);
        [(tile.focused ? self.accent : self.muted) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:mark xRadius:1 yRadius:1] fill];
    }
}
@end

@interface AXNode : NSObject
@property(assign) AXUIElementRef element;
@end
@implementation AXNode
- (instancetype)initWithElement:(AXUIElementRef)element {
    self = [super init];
    if (self && element) {
        CFRetain(element);
        _element = element;
    }
    return self;
}
- (void)dealloc {
    if (_element) CFRelease(_element);
}
@end

@interface DockTarget : NSObject
@property(assign) pid_t pid;
@property(strong) AXNode *windowNode;
@property(strong) AXNode *tabNode;
@end
@implementation DockTarget
@end

static NSString *axString(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (!element || AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    return (__bridge_transfer NSString *)value;
}

static NSString *menuTitle(NSString *raw) {
    NSString *title = [[raw stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (title.length > 90) title = [[title substringToIndex:87] stringByAppendingString:@"…"];
    return title.length ? title : nil;
}

static BOOL axSelected(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXSelected"), &value) != kAXErrorSuccess || !value) return NO;
    BOOL on = CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    CFRelease(value);
    return on;
}

static BOOL axFlag(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (!element || AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return NO;
    BOOL on = CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    CFRelease(value);
    return on;
}

// The system Dock lists real windows, including minimized ones, and skips
// the tiny panels some apps keep around.
static BOOL axWindowListed(AXUIElementRef window) {
    if (axFlag(window, kAXMinimizedAttribute)) return YES;
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &value) != kAXErrorSuccess || !value) return YES;
    CGSize size = CGSizeZero;
    BOOL ok = AXValueGetValue((AXValueRef)value, kAXValueCGSizeType, &size);
    CFRelease(value);
    if (!ok) return YES;
    return size.width >= 80 && size.height >= 40;
}

static NSString *axTabTitle(AXUIElementRef element) {
    NSString *title = menuTitle(axString(element, kAXTitleAttribute));
    if (title) return title;
    return menuTitle(axString(element, kAXDescriptionAttribute));
}

static void collectTabs(AXUIElementRef element, int depth, BOOL inTabs, NSMutableArray<AXNode *> *tabs) {
    if (depth > 16 || tabs.count > 80) return;
    NSString *role = axString(element, kAXRoleAttribute) ?: @"";
    NSString *sub = axString(element, kAXSubroleAttribute) ?: @"";
    if ([role isEqualToString:@"AXWebArea"]) return;
    BOOL tabGroup = inTabs || [role isEqualToString:@"AXTabGroup"] || [sub isEqualToString:@"AXTabGroup"] || [role isEqualToString:@"AXTab"];
    BOOL isTab = [role isEqualToString:@"AXTab"] || [sub isEqualToString:@"AXTabButton"]
        || (tabGroup && [role isEqualToString:@"AXRadioButton"]);
    if (isTab && axTabTitle(element)) [tabs addObject:[[AXNode alloc] initWithElement:element]];
    BOOL dive = [role isEqualToString:@"AXWindow"] || [role isEqualToString:@"AXGroup"] || [role isEqualToString:@"AXSplitGroup"]
        || [role isEqualToString:@"AXToolbar"] || [role isEqualToString:@"AXScrollArea"] || [role isEqualToString:@"AXList"]
        || [role containsString:@"Tab"] || role.length == 0;
    if (!dive && !tabGroup) return;
    CFArrayRef kids = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, (CFTypeRef *)&kids) != kAXErrorSuccess || !kids) return;
    for (CFIndex i = 0, n = CFArrayGetCount(kids); i < n && tabs.count < 80; i++) {
        collectTabs((AXUIElementRef)CFArrayGetValueAtIndex(kids, i), depth + 1, tabGroup, tabs);
    }
    CFRelease(kids);
}

@implementation DockController {
    NSMutableArray<NSWindow *> *_strips;
    EdgePanel *_dock;
    CapsuleView *_capsule;
    NSScreen *_screen;
    BOOL _shown;
    int _generation;
    int _leaveToken;
    NSColor *_fill, *_accent, *_muted;
    dispatch_source_t _themeSource;
    int _themeFD;
    NSMutableDictionary<NSString *, NSImage *> *_icons;
    NSMutableDictionary<NSString *, NSString *> *_bundleIDs;
    NSArray<NSString *> *_extraOrder;
    BOOL _dragWasPinned;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _strips = [NSMutableArray array];
    _icons = [NSMutableDictionary dictionary];
    _bundleIDs = [NSMutableDictionary dictionary];
    _fill = NSColor.blackColor;
    _accent = NSColor.whiteColor;
    _muted = NSColor.grayColor;
    _extraOrder = [NSArray arrayWithContentsOfFile:[self extraOrderPath]] ?: @[];
    return self;
}

- (NSString *)extraOrderPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".local/state/omacosy/dock-extra-order.plist"];
}

- (NSInteger)extraRank:(NSString *)bundleID {
    NSUInteger idx = [_extraOrder indexOfObject:bundleID];
    return idx == NSNotFound ? NSIntegerMax : (NSInteger)idx;
}

- (NSInteger)splitOf:(NSArray<DockTile *> *)tiles {
    NSInteger split = 0;
    for (DockTile *tile in tiles) {
        if (!tile.pinned) break;
        split++;
    }
    return split;
}

- (void)start {
    [self loadPalette];
    [self watchTheme];
    [self buildDock];
    [self rebuildStrips];
    [self burySystemDock];
    [self guardSystemDockEdge];
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    fprintf(stderr, "omacosy-dock: accessibility %d\n", AXIsProcessTrusted());
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification,
                                      NSWorkspaceDidTerminateApplicationNotification,
                                      NSWorkspaceDidActivateApplicationNotification]) {
        [nc addObserver:self selector:@selector(appsChanged:) name:name object:nil];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
    note("up");
}

- (void)loadPalette {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/omarchy/current/theme/sketchybar.sh"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByReplacingOccurrencesOfString:@"export " withString:@""];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];
        if (![value hasPrefix:@"0x"]) continue;
        unsigned long argb = strtoul(value.UTF8String, NULL, 16);
        NSColor *color = colorFromARGB(argb);
        if ([key isEqualToString:@"ITEM_BG"]) _fill = color;
        else if ([key isEqualToString:@"ACCENT"]) _accent = color;
        else if ([key isEqualToString:@"MUTED"]) _muted = color;
    }
    _capsule.fill = _fill;
    _capsule.accent = _accent;
    _capsule.muted = _muted;
    [_capsule setNeedsDisplay:YES];
}

- (void)watchTheme {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/omarchy/current"];
    _themeFD = open(path.fileSystemRepresentation, O_EVTONLY);
    if (_themeFD < 0) return;
    _themeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, _themeFD,
                                          DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
                                          dispatch_get_main_queue());
    __weak DockController *weakSelf = self;
    dispatch_source_set_event_handler(_themeSource, ^{
        DockController *self_ = weakSelf;
        if (!self_) return;
        [self_ loadPalette];
        if (dispatch_source_get_data(self_->_themeSource) & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
            dispatch_source_cancel(self_->_themeSource);
            close(self_->_themeFD);
            self_->_themeFD = -1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self_ watchTheme];
            });
        }
    });
    dispatch_source_set_cancel_handler(_themeSource, ^{});
    dispatch_resume(_themeSource);
}

- (void)buildDock {
    _dock = [[EdgePanel alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered defer:NO];
    _dock.opaque = NO;
    // A fully clear window drops clicks on pixels that aren't painted.
    // The right-hand icons were the ones that fell through.
    _dock.backgroundColor = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.02];
    _dock.hasShadow = NO;
    _dock.becomesKeyOnlyIfNeeded = YES;
    _dock.hidesOnDeactivate = NO;
    _dock.level = kDockLevel;
    _dock.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorStationary
        | NSWindowCollectionBehaviorIgnoresCycle
        | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _capsule = [[CapsuleView alloc] initWithFrame:NSZeroRect];
    _capsule.fill = _fill;
    _capsule.accent = _accent;
    _capsule.muted = _muted;
    _dock.contentView = _capsule;
}

- (void)rebuildStrips {
    for (NSWindow *strip in _strips) [strip orderOut:nil];
    [_strips removeAllObjects];
    for (NSScreen *screen in NSScreen.screens) {
        NSRect frame = NSMakeRect(screen.frame.origin.x, screen.frame.origin.y, screen.frame.size.width, kStripHeight);
        EdgeWindow *window = [[EdgeWindow alloc] initWithContentRect:frame
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered defer:NO];
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = NO;
        window.level = kStripLevel;
        window.collectionBehavior = _dock.collectionBehavior;
        HitView *hit = [[HitView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        window.contentView = hit;
        [window orderFrontRegardless];
        [_strips addObject:window];
    }
}

- (void)screensChanged:(NSNotification *)note { [self rebuildStrips]; }

- (NSString *)bundleIDForURL:(NSURL *)url {
    NSString *key = normPath(url.path);
    NSString *cached = _bundleIDs[key];
    if (cached) return cached.length ? cached : nil;
    NSString *bid = [NSBundle bundleWithURL:url].bundleIdentifier ?: @"";
    _bundleIDs[key] = bid;
    return bid.length ? bid : nil;
}

- (NSImage *)iconForURL:(NSURL *)url {
    NSString *key = normPath(url.path);
    NSImage *cached = _icons[key];
    if (cached) return cached;
    NSImage *image = [NSWorkspace.sharedWorkspace iconForFile:url.path];
    image.template = NO;
    if (image) _icons[key] = image;
    return image;
}

- (NSMutableArray *)persistentApps {
    CFArrayRef raw = CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    NSMutableArray *apps = raw ? [(__bridge NSArray *)raw mutableCopy] : [NSMutableArray array];
    if (raw) CFRelease(raw);
    return apps;
}

- (void)setPersistentApps:(NSArray *)apps {
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (__bridge CFArrayRef)apps, CFSTR("com.apple.dock"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
}

- (NSArray<DockTile *> *)tilesSplit:(NSInteger *)splitAt {
    NSMutableArray<NSURL *> *pinned = [NSMutableArray array];
    NSMutableSet<NSString *> *pinnedIDs = [NSMutableSet set];
    for (NSDictionary *entry in [self persistentApps]) {
        NSString *raw = entry[@"tile-data"][@"file-data"][@"_CFURLString"];
        NSURL *url = raw ? [NSURL URLWithString:raw] : nil;
        if (!url || ![url.pathExtension isEqualToString:@"app"]) continue;
        if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) continue;
        [pinned addObject:url];
        NSString *bid = entry[@"tile-data"][@"bundle-identifier"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) bid = [self bundleIDForURL:url];
        if (bid.length) {
            _bundleIDs[normPath(url.path)] = bid;
            [pinnedIDs addObject:bid];
        }
    }
    NSMutableSet<NSString *> *runningIDs = [NSMutableSet set];
    NSMutableArray<NSRunningApplication *> *extraApps = [NSMutableArray array];
    NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (!app.bundleIdentifier || !app.bundleURL) continue;
        [runningIDs addObject:app.bundleIdentifier];
        if ([pinnedIDs containsObject:app.bundleIdentifier]) continue;
        [extraApps addObject:app];
    }
    [extraApps sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        NSInteger ia = [self extraRank:a.bundleIdentifier];
        NSInteger ib = [self extraRank:b.bundleIdentifier];
        if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        return [a.localizedName localizedStandardCompare:b.localizedName];
    }];
    NSMutableArray<DockTile *> *tiles = [NSMutableArray array];
    void (^add)(NSURL *, BOOL) = ^(NSURL *url, BOOL isPinned) {
        NSString *bid = [self bundleIDForURL:url];
        DockTile *tile = [DockTile new];
        tile.url = url;
        tile.bundleID = bid;
        tile.name = [NSBundle bundleWithURL:url].infoDictionary[@"CFBundleDisplayName"]
            ?: [NSBundle bundleWithURL:url].infoDictionary[@"CFBundleName"]
            ?: url.lastPathComponent.stringByDeletingPathExtension;
        tile.icon = [self iconForURL:url];
        tile.running = bid && [runningIDs containsObject:bid];
        tile.focused = bid && [bid isEqualToString:front];
        tile.pinned = isPinned;
        [tiles addObject:tile];
    };
    for (NSURL *url in pinned) add(url, YES);
    *splitAt = (NSInteger)tiles.count;
    for (NSRunningApplication *app in extraApps) add(app.bundleURL, NO);
    return tiles;
}

- (void)placeTiles:(NSArray<DockTile *> *)tiles splitAt:(NSInteger)splitAt maxWidth:(CGFloat)maxWidth headroom:(CGFloat)headroom {
    NSInteger count = (NSInteger)tiles.count;
    BOOL hasSplit = splitAt > 0 && splitAt < count;
    CGFloat between = MAX(0, count - 1) * kGap + (hasSplit ? (kSplit - kGap) : 0);
    CGFloat icon = kIcon;
    CGFloat room = maxWidth - kPadX * 2 - between;
    if (count > 0 && room < count * icon) icon = MAX(18, room / count);
    CGFloat x = kPadX;
    CGFloat splitX = 0;
    for (NSInteger i = 0; i < count; i++) {
        if (i > 0) {
            CGFloat gap = (hasSplit && i == splitAt) ? kSplit : kGap;
            if (hasSplit && i == splitAt) splitX = x + gap / 2;
            x += gap;
        }
        tiles[i].rect = NSMakeRect(x, kLift + kPadY, icon, icon);
        x += icon;
    }
    NSSize size = NSMakeSize(x + kPadX, icon + kPadY * 2 + kLift + headroom);
    for (NSInteger i = 0; i < count; i++) {
        CGFloat left = 0;
        CGFloat right = size.width;
        if (i > 0) left = (NSMidX(tiles[i - 1].rect) + NSMidX(tiles[i].rect)) / 2;
        if (i + 1 < count) right = (NSMidX(tiles[i].rect) + NSMidX(tiles[i + 1].rect)) / 2;
        tiles[i].hit = NSMakeRect(left, 0, MAX(1, right - left), size.height);
    }
    _capsule.tiles = tiles;
    _capsule.hasSplit = hasSplit;
    _capsule.splitX = splitX;
    _capsule.frame = NSMakeRect(0, 0, size.width, size.height);
}

- (void)showOnScreen:(NSScreen *)screen {
    if (!screen || self.menuOpen || self.dragging) return;
    _leaveToken++;
    if (_shown && _screen == screen) return;
    NSInteger splitAt = 0;
    NSArray<DockTile *> *tiles = [self tilesSplit:&splitAt];
    if (tiles.count == 0) return;
    BOOL animate = !_shown;
    _shown = YES;
    _screen = screen;
    _generation++;
    [self placeTiles:tiles splitAt:splitAt maxWidth:screen.frame.size.width - 24 headroom:0];
    NSSize size = _capsule.frame.size;
    NSRect frame = NSMakeRect(NSMidX(screen.frame) - size.width / 2, screen.frame.origin.y, size.width, size.height);
    _dock.ignoresMouseEvents = NO;
    if (animate) {
        [_dock setFrame:NSOffsetRect(frame, 0, -frame.size.height - 12) display:NO];
        [_dock orderFrontRegardless];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.18;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [[self->_dock animator] setFrame:frame display:YES];
        }];
    } else {
        [_dock setFrame:frame display:YES];
        [_dock orderFrontRegardless];
    }
    [_capsule setNeedsDisplay:YES];
}

- (void)pointerEnteredCapsule { _leaveToken++; }

- (void)pointerLeft {
    if (!_shown || self.menuOpen || self.dragging) return;
    int token = ++_leaveToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_leaveToken || !self->_shown || self.menuOpen) return;
        if ([self pointerInside]) return;
        [self hide];
    });
}

- (BOOL)pointerInside {
    NSPoint p = NSEvent.mouseLocation;
    if (_shown && NSPointInRect(p, NSInsetRect(_dock.frame, -8, -8))) return YES;
    for (NSWindow *strip in _strips) {
        if (NSPointInRect(p, NSInsetRect(strip.frame, 0, -4))) return YES;
    }
    return NO;
}

- (void)hide {
    if (!_shown || self.menuOpen || self.dragging) return;
    _shown = NO;
    int generation = ++_generation;
    _dock.ignoresMouseEvents = YES;
    NSRect frame = _dock.frame;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.16;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        [[self->_dock animator] setFrame:NSOffsetRect(frame, 0, -frame.size.height - 12) display:YES];
    } completionHandler:^{
        if (generation == self->_generation) [self->_dock orderOut:nil];
    }];
}

- (void)fitWindow {
    if (!_screen) return;
    NSSize size = _capsule.frame.size;
    [_dock setFrame:NSMakeRect(NSMidX(_screen.frame) - size.width / 2, _screen.frame.origin.y, size.width, size.height) display:YES];
}

- (void)appsChanged:(NSNotification *)note {
    if (!_shown || !_screen || self.menuOpen || self.dragging) return;
    NSInteger splitAt = 0;
    NSArray<DockTile *> *tiles = [self tilesSplit:&splitAt];
    if (tiles.count == 0) { [self hide]; return; }
    [self placeTiles:tiles splitAt:splitAt maxWidth:_screen.frame.size.width - 24 headroom:0];
    [self fitWindow];
    [_capsule setNeedsDisplay:YES];
}

- (void)beginReorder:(DockTile *)tile {
    if (!tile || !_shown) return;
    self.dragging = YES;
    _dragWasPinned = tile.pinned;
    _leaveToken++;
    _capsule.dragTile = tile;
    NSInteger split = [self splitOf:_capsule.tiles];
    [self placeTiles:_capsule.tiles splitAt:split maxWidth:_screen.frame.size.width - 24 headroom:kDragHeadroom];
    [self fitWindow];
    [_capsule setNeedsDisplay:YES];
}

- (void)reorderTile:(DockTile *)tile toViewPoint:(NSPoint)point {
    NSMutableArray<DockTile *> *tiles = [_capsule.tiles mutableCopy];
    NSInteger from = [tiles indexOfObjectIdenticalTo:tile];
    if (from == NSNotFound) return;
    NSInteger to = (NSInteger)tiles.count;
    for (NSInteger i = 0; i < (NSInteger)tiles.count; i++) {
        if (point.x < NSMidX(tiles[i].rect)) { to = i; break; }
    }
    if (to != from && to != from + 1) {
        [tiles removeObjectAtIndex:(NSUInteger)from];
        if (to > from) to--;
        NSInteger splitNow = [self splitOf:tiles];
        if (_dragWasPinned) {
            if (to > splitNow) to = splitNow;
            tile.pinned = YES;
        } else {
            tile.pinned = splitNow == (NSInteger)tiles.count || to < splitNow;
        }
        [tiles insertObject:tile atIndex:(NSUInteger)MIN(to, (NSInteger)tiles.count)];
        [self placeTiles:tiles splitAt:[self splitOf:tiles] maxWidth:_screen.frame.size.width - 24 headroom:kDragHeadroom];
        [self fitWindow];
    }
    _capsule.dragTile = tile;
    [_capsule setNeedsDisplay:YES];
}

- (void)endReorder {
    NSArray<DockTile *> *tiles = _capsule.tiles ?: @[];
    NSInteger split = [self splitOf:tiles];
    if (split > 0) [self savePinnedOrder:[tiles subarrayWithRange:NSMakeRange(0, (NSUInteger)split)]];
    NSMutableArray<NSString *> *extras = [NSMutableArray array];
    for (NSInteger i = split; i < (NSInteger)tiles.count; i++) {
        if (tiles[i].bundleID.length) [extras addObject:tiles[i].bundleID];
    }
    if (extras.count && ![extras isEqualToArray:_extraOrder]) {
        _extraOrder = [extras copy];
        NSString *path = [self extraOrderPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [extras writeToFile:path atomically:YES];
    }
    _capsule.dragTile = nil;
    [self placeTiles:tiles splitAt:split maxWidth:_screen.frame.size.width - 24 headroom:0];
    [self fitWindow];
    self.dragging = NO;
    [_capsule setNeedsDisplay:YES];
    if (![self pointerInside]) [self pointerLeft];
}

- (void)savePinnedOrder:(NSArray<DockTile *> *)pinnedTiles {
    NSMutableArray *apps = [self persistentApps];
    NSMutableArray *rebuilt = [NSMutableArray array];
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    for (DockTile *tile in pinnedTiles) {
        id found = nil;
        for (NSUInteger i = 0; i < apps.count; i++) {
            if ([used containsIndex:i]) continue;
            if ([self entry:apps[i] matchesTile:tile]) {
                found = apps[i];
                [used addIndex:i];
                break;
            }
        }
        [rebuilt addObject:found ?: [self entryForTile:tile]];
    }
    if (used.count == rebuilt.count) {
        BOOL same = YES;
        NSUInteger n = 0;
        for (NSUInteger i = 0; i < apps.count && n < rebuilt.count; i++) {
            if (![used containsIndex:i]) continue;
            if (apps[i] != rebuilt[n]) { same = NO; break; }
            n++;
        }
        if (same) return;
    }
    NSMutableArray *result = [NSMutableArray array];
    BOOL placed = NO;
    for (NSUInteger i = 0; i < apps.count; i++) {
        if ([used containsIndex:i]) {
            if (!placed) {
                [result addObjectsFromArray:rebuilt];
                placed = YES;
            }
            continue;
        }
        [result addObject:apps[i]];
    }
    if (!placed) [result addObjectsFromArray:rebuilt];
    [self setPersistentApps:result];
}

- (NSRunningApplication *)runningForTile:(DockTile *)tile {
    if (!tile.bundleID.length) return nil;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:tile.bundleID]) {
        if (!app.terminated) return app;
    }
    return nil;
}

- (void)openTile:(DockTile *)tile {
    NSURL *url = tile.url;
    NSRunningApplication *running = [self runningForTile:tile];
    // Already on screen: just bring it forward. No window at all (the usual
    // case for an icon on the right): launch or reopen so one appears.
    // openApplicationAtURL returns immediately; the old activate call blocked
    // the click until the target app answered.
    BOOL visible = running && appHasVisibleWindow(running.processIdentifier);
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = YES;
    config.addsToRecentItems = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:config completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (app && !visible) reopenApp(app.processIdentifier);
        if (error) fprintf(stderr, "omacosy-dock: open %s\n", error.localizedDescription.UTF8String);
    }];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action tile:(DockTile *)tile {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = tile;
    return item;
}

- (BOOL)browserTile:(DockTile *)tile {
    NSString *bid = tile.bundleID ?: @"";
    return [bid isEqualToString:@"com.google.Chrome"]
        || [bid isEqualToString:@"com.google.Chrome.canary"]
        || [bid isEqualToString:@"com.apple.Safari"]
        || [bid isEqualToString:@"org.mozilla.firefox"]
        || [bid isEqualToString:@"com.microsoft.edgemac"]
        || [bid isEqualToString:@"com.brave.Browser"]
        || [bid isEqualToString:@"company.thebrowser.Browser"]
        || [bid isEqualToString:@"org.chromium.Chromium"];
}

- (NSMenuItem *)targetItem:(NSString *)title window:(AXNode *)window tab:(AXNode *)tab pid:(pid_t)pid selected:(BOOL)selected {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(menuFocusTarget:) keyEquivalent:@""];
    item.target = self;
    item.enabled = YES;
    if (selected) item.state = NSControlStateValueOn;
    DockTarget *target = [DockTarget new];
    target.pid = pid;
    target.windowNode = window;
    target.tabNode = tab;
    item.representedObject = target;
    return item;
}

- (void)addWindowItems:(NSMenu *)menu tile:(DockTile *)tile {
    NSRunningApplication *app = [self runningForTile:tile];
    if (!app || !AXIsProcessTrusted()) return;
    AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
    CFArrayRef rawWindows = NULL;
    AXError err = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, (CFTypeRef *)&rawWindows);
    CFRelease(application);
    if (err != kAXErrorSuccess || !rawWindows) return;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (CFIndex i = 0, n = CFArrayGetCount(rawWindows); i < n; i++) {
        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(rawWindows, i);
        NSString *title = menuTitle(axString(window, kAXTitleAttribute));
        if (!title.length) title = zh() ? @"未命名" : @"Untitled";
        NSMutableArray<AXNode *> *tabs = [NSMutableArray array];
        if ([self browserTile:tile]) collectTabs(window, 0, NO, tabs);
        if (!tabs.count && !axWindowListed(window)) continue;
        [sections addObject:@{
            @"title": title,
            @"window": [[AXNode alloc] initWithElement:window],
            @"tabs": tabs,
        }];
    }
    CFRelease(rawWindows);
    if (!sections.count) return;
    [menu addItem:[NSMenuItem separatorItem]];
    BOOL group = sections.count > 1;
    for (NSDictionary *section in sections) {
        NSString *title = section[@"title"];
        AXNode *window = section[@"window"];
        NSArray<AXNode *> *tabs = section[@"tabs"];
        if (tabs.count && group) {
            NSMenu *sub = [NSMenu new];
            sub.autoenablesItems = NO;
            for (AXNode *tab in tabs) {
                NSString *tabTitle = axTabTitle(tab.element);
                if (!tabTitle) continue;
                [sub addItem:[self targetItem:tabTitle window:window tab:tab pid:app.processIdentifier selected:axSelected(tab.element)]];
            }
            NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:(title.length ? title : (zh() ? @"窗口" : @"Window")) action:NULL keyEquivalent:@""];
            parent.submenu = sub;
            [menu addItem:parent];
        } else if (tabs.count) {
            for (AXNode *tab in tabs) {
                NSString *tabTitle = axTabTitle(tab.element);
                if (!tabTitle) continue;
                [menu addItem:[self targetItem:tabTitle window:window tab:tab pid:app.processIdentifier selected:axSelected(tab.element)]];
            }
        } else {
            [menu addItem:[self targetItem:title window:window tab:nil pid:app.processIdentifier selected:NO]];
        }
    }
}

- (NSMenu *)menuForTile:(DockTile *)tile {
    BOOL chinese = zh();
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    [menu addItem:[self item:(chinese ? @"打开" : @"Open") action:@selector(menuOpen:) tile:tile]];
    if (tile.running && !AXIsProcessTrusted()) {
        NSMenuItem *allow = [[NSMenuItem alloc] initWithTitle:(chinese ? @"允许辅助功能以列出窗口和标签页" : @"Allow Accessibility to list windows and tabs")
                                                       action:@selector(menuAllowAccessibility:)
                                                keyEquivalent:@""];
        allow.target = self;
        [menu addItem:allow];
    } else {
        [self addWindowItems:menu tile:tile];
    }

    NSMenu *options = [NSMenu new];
    options.autoenablesItems = NO;
    NSMenuItem *keep = [self item:(chinese ? @"在下栏中保留" : @"Keep in Dock") action:@selector(menuTogglePin:) tile:tile];
    keep.state = tile.pinned ? NSControlStateValueOn : NSControlStateValueOff;
    [options addItem:keep];
    NSMenuItem *login = [self item:(chinese ? @"登录时打开" : @"Open at Login") action:@selector(menuToggleLogin:) tile:tile];
    login.state = loginItemEnabled(tile.url) ? NSControlStateValueOn : NSControlStateValueOff;
    [options addItem:login];
    [options addItem:[self item:(chinese ? @"在访达中显示" : @"Show in Finder") action:@selector(menuReveal:) tile:tile]];
    NSMenuItem *optionsItem = [[NSMenuItem alloc] initWithTitle:(chinese ? @"选项" : @"Options") action:NULL keyEquivalent:@""];
    optionsItem.submenu = options;
    [menu addItem:optionsItem];

    if (tile.running) {
        [menu addItem:[NSMenuItem separatorItem]];
        if (tile.focused) [menu addItem:[self item:(chinese ? @"隐藏" : @"Hide") action:@selector(menuHide:) tile:tile]];
        BOOL option = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
        [menu addItem:[self item:(option ? (chinese ? @"强制退出" : @"Force Quit") : (chinese ? @"退出" : @"Quit"))
                            action:(option ? @selector(menuForceQuit:) : @selector(menuQuit:))
                              tile:tile]];
    }
    return menu;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    BOOL option = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    BOOL chinese = zh();
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action != @selector(menuQuit:) && item.action != @selector(menuForceQuit:)) continue;
        item.title = option ? (chinese ? @"强制退出" : @"Force Quit") : (chinese ? @"退出" : @"Quit");
        item.action = option ? @selector(menuForceQuit:) : @selector(menuQuit:);
    }
}

- (void)menuAllowAccessibility:(NSMenuItem *)item {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)menuOpen:(NSMenuItem *)item { [self openTile:item.representedObject]; }

- (void)menuFocusTarget:(NSMenuItem *)item {
    DockTarget *target = item.representedObject;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:target.pid];
    if ([app respondsToSelector:@selector(activateFromApplication:options:)]) {
        [app activateFromApplication:NSRunningApplication.currentApplication options:NSApplicationActivateAllWindows];
    } else {
        [app activateWithOptions:NSApplicationActivateAllWindows];
    }
    if (target.windowNode.element) {
        AXUIElementSetAttributeValue(target.windowNode.element, CFSTR("AXMinimized"), kCFBooleanFalse);
        AXUIElementPerformAction(target.windowNode.element, kAXRaiseAction);
    }
    if (target.tabNode.element) AXUIElementPerformAction(target.tabNode.element, kAXPressAction);
}

- (void)menuReveal:(NSMenuItem *)item {
    DockTile *tile = item.representedObject;
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[tile.url]];
}

- (NSDictionary *)entryForTile:(DockTile *)tile {
    NSString *string = tile.url.absoluteString;
    if (![string hasSuffix:@"/"]) string = [string stringByAppendingString:@"/"];
    NSMutableDictionary *data = [@{
        @"file-label": tile.name ?: @"",
        @"file-type": @41,
        @"file-data": @{ @"_CFURLString": string, @"_CFURLStringType": @15 },
    } mutableCopy];
    if (tile.bundleID.length) data[@"bundle-identifier"] = tile.bundleID;
    return @{ @"tile-type": @"file-tile", @"GUID": @(arc4random()), @"tile-data": data };
}

- (BOOL)entry:(NSDictionary *)entry matchesTile:(DockTile *)tile {
    NSString *bid = entry[@"tile-data"][@"bundle-identifier"];
    if (tile.bundleID.length && [bid isKindOfClass:NSString.class] && [bid isEqualToString:tile.bundleID]) return YES;
    NSString *raw = entry[@"tile-data"][@"file-data"][@"_CFURLString"];
    NSURL *url = [raw isKindOfClass:NSString.class] ? [NSURL URLWithString:raw] : nil;
    return url && [normPath(url.path) isEqualToString:normPath(tile.url.path)];
}

- (void)menuTogglePin:(NSMenuItem *)item {
    DockTile *tile = item.representedObject;
    NSMutableArray *apps = [self persistentApps];
    NSInteger found = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)apps.count; i++) {
        if ([self entry:apps[i] matchesTile:tile]) { found = i; break; }
    }
    if (found != NSNotFound) [apps removeObjectAtIndex:(NSUInteger)found];
    else [apps addObject:[self entryForTile:tile]];
    [self setPersistentApps:apps];
    self.menuOpen = NO;
    [self appsChanged:nil];
}

- (void)menuToggleLogin:(NSMenuItem *)item {
    DockTile *tile = item.representedObject;
    setLoginItem(tile.url, !loginItemEnabled(tile.url));
}

- (void)menuHide:(NSMenuItem *)item {
    [[self runningForTile:item.representedObject] hide];
}

- (void)menuQuit:(NSMenuItem *)item {
    [[self runningForTile:item.representedObject] terminate];
}

- (void)menuForceQuit:(NSMenuItem *)item {
    [[self runningForTile:item.representedObject] forceTerminate];
}

- (void)showTest {
    [self showOnScreen:NSScreen.mainScreen ?: NSScreen.screens.firstObject];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self hide];
    });
}

- (double)dockPref:(CFStringRef)key fallback:(double)fallback {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(key, CFSTR("com.apple.dock"));
    double value = fallback;
    if (raw && CFGetTypeID(raw) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)raw, kCFNumberDoubleType, &value);
    if (raw) CFRelease(raw);
    return value;
}

- (void)rememberDockPref:(NSString *)name value:(double)value {
    NSString *marker = [[NSHomeDirectory() stringByAppendingPathComponent:@".local/state/omacosy"] stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:marker.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%g", value] writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)burySystemDock {
    // autohide-delay stops the normal space. Fullscreen uses a separate
    // edge gesture; stretching the slide makes that gesture finish off screen.
    double delay = [self dockPref:CFSTR("autohide-delay") fallback:0.05];
    double modifier = [self dockPref:CFSTR("autohide-time-modifier") fallback:0.35];
    BOOL changed = NO;
    if (delay < 30) {
        [self rememberDockPref:@"dock-autohide-delay" value:delay];
        CFPreferencesSetAppValue(CFSTR("autohide-delay"), (__bridge CFNumberRef)@(1000.0), CFSTR("com.apple.dock"));
        CFPreferencesSetAppValue(CFSTR("autohide"), kCFBooleanTrue, CFSTR("com.apple.dock"));
        changed = YES;
    }
    if (modifier < 30) {
        [self rememberDockPref:@"dock-autohide-time-modifier" value:modifier];
        CFPreferencesSetAppValue(CFSTR("autohide-time-modifier"), (__bridge CFNumberRef)@(1000.0), CFSTR("com.apple.dock"));
        changed = YES;
    }
    if (!changed) return;
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    NSTask *kill = [NSTask new];
    kill.executableURL = [NSURL fileURLWithPath:@"/usr/bin/killall"];
    kill.arguments = @[@"Dock"];
    [kill launchAndReturnError:nil];
    note("system Dock held back");
}

// Fullscreen reveal ignores autohide-delay. It starts when the pointer
// reaches the bottom two points, including a push that stays there.
// Hold the pointer just inside the hit strip so that gesture never lands.
static CFMachPortRef edgePort;

static CGPoint guardBottomEdge(CGPoint p) {
    uint32_t count = 0;
    CGDirectDisplayID ids[8];
    if (CGGetActiveDisplayList(8, ids, &count) != kCGErrorSuccess) return p;
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        if (p.x < CGRectGetMinX(b) - 1 || p.x > CGRectGetMaxX(b) + 1) continue;
        CGFloat limit = CGRectGetMaxY(b) - kEdgeGuard;
        if (p.y > limit) p.y = limit;
        break;
    }
    return p;
}

static CGEventRef edgeTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *ref) {
    (void)proxy;
    (void)ref;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (edgePort) CGEventTapEnable(edgePort, true);
        return event;
    }
    CGPoint p = CGEventGetLocation(event);
    CGPoint q = guardBottomEdge(p);
    if (q.y != p.y) CGEventSetLocation(event, q);
    return event;
}

static SLSConnectionID slsCID;
static NSMutableSet<NSNumber *> *hiddenDockIDs;

static BOOL nearBottomEdge(CGPoint p) {
    uint32_t count = 0;
    CGDirectDisplayID ids[8];
    if (CGGetActiveDisplayList(8, ids, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        if (p.x < CGRectGetMinX(b) - 1 || p.x > CGRectGetMaxX(b) + 1) continue;
        if (p.y > CGRectGetMaxY(b) - 48) return YES;
    }
    return NO;
}

static void hideSystemDockChrome(void) {
    if (!slsCID) slsCID = SLSMainConnectionID();
    if (!hiddenDockIDs) hiddenDockIDs = [NSMutableSet set];
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!list) return;
    for (NSDictionary *window in (__bridge NSArray *)list) {
        if (![window[(id)kCGWindowOwnerName] isEqualToString:@"Dock"]) continue;
        NSString *name = window[(id)kCGWindowName] ?: @"";
        NSDictionary *bounds = window[(id)kCGWindowBounds];
        double height = [bounds[@"Height"] doubleValue];
        double width = [bounds[@"Width"] doubleValue];
        // The name pill is a layer in the full-screen Dock window, or a
        // small window of its own. Mission Control is a different window.
        BOOL chrome = [name isEqualToString:@"Dock"] || (height > 0 && height < 120 && width > 16 && width < 900);
        if (!chrome) continue;
        uint32_t wid = [window[(id)kCGWindowNumber] unsignedIntValue];
        if (!wid) continue;
        SLSSetWindowAlpha(slsCID, wid, 0);
        [hiddenDockIDs addObject:@(wid)];
    }
    CFRelease(list);
}

static void restoreSystemDockChrome(void) {
    if (!slsCID || hiddenDockIDs.count == 0) return;
    for (NSNumber *wid in hiddenDockIDs) SLSSetWindowAlpha(slsCID, wid.unsignedIntValue, 1);
    [hiddenDockIDs removeAllObjects];
}

- (void)guardSystemDockEdge {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
        | CGEventMaskBit(kCGEventLeftMouseDragged)
        | CGEventMaskBit(kCGEventRightMouseDragged)
        | CGEventMaskBit(kCGEventOtherMouseDragged);
    edgePort = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, edgeTap, NULL);
    if (edgePort) {
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, edgePort, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(edgePort, true);
        CFRelease(src);
    }
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *unused) {
        (void)unused;
        CGEventRef event = CGEventCreate(NULL);
        if (!event) return;
        CGPoint p = CGEventGetLocation(event);
        CFRelease(event);
        CGPoint q = guardBottomEdge(p);
        if (q.y != p.y) CGWarpMouseCursorPosition(q);
        if (nearBottomEdge(q)) hideSystemDockChrome();
        else restoreSystemDockChrome();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        controller = [DockController new];
        signal(SIGUSR1, SIG_IGN);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ [controller showTest]; });
        dispatch_resume(src);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{
            restoreSystemDockChrome();
            exit(0);
        });
        dispatch_resume(term);
        [controller start];
        [NSApp run];
    }
    return 0;
}
