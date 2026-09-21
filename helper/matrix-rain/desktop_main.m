#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <signal.h>
#import <math.h>
#import "MatrixRain.h"

static float RainCellHeight(CGFloat pointHeight) {
    (void)pointHeight;
    return 16.f;
}

@interface RainApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@end

@implementation RainApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.windows = [NSMutableArray array];
    [self rebuildWindows];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildWindows)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    [ws.notificationCenter addObserver:self selector:@selector(rebuildWindows) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [ws.notificationCenter addObserver:self selector:@selector(pauseRain) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [ws.notificationCenter addObserver:self selector:@selector(resumeRain) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [ws.notificationCenter addObserver:self selector:@selector(pauseRain) name:NSWorkspaceWillSleepNotification object:nil];
    [ws.notificationCenter addObserver:self selector:@selector(resumeRain) name:NSWorkspaceDidWakeNotification object:nil];
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(pauseRain) name:@"com.apple.screensaver.didstart" object:nil];
    [dnc addObserver:self selector:@selector(resumeRain) name:@"com.apple.screensaver.didstop" object:nil];
    [dnc addObserver:self selector:@selector(pauseRain) name:@"com.apple.screenIsLocked" object:nil];
    [dnc addObserver:self selector:@selector(resumeRain) name:@"com.apple.screenIsUnlocked" object:nil];
    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ [self restartAll]; });
    dispatch_resume(src);
}

- (void)setRainPaused:(BOOL)paused {
    for (NSWindow *window in self.windows) {
        MatrixRainView *view = (MatrixRainView *)window.contentView;
        if ([view isKindOfClass:[MatrixRainView class]])
            view.paused = paused;
        if (paused)
            [window orderOut:nil];
        else
            [window orderBack:nil];
    }
}

- (void)pauseRain { [self setRainPaused:YES]; }
- (void)resumeRain { [self setRainPaused:NO]; }

- (void)restartAll {
    for (NSWindow *window in self.windows) {
        MatrixRainView *view = (MatrixRainView *)window.contentView;
        if ([view isKindOfClass:[MatrixRainView class]])
            [view restart];
    }
}

- (void)rebuildWindows {
    for (NSWindow *window in self.windows) {
        [window orderOut:nil];
    }
    [self.windows removeAllObjects];

    for (NSScreen *screen in [NSScreen screens]) {
        NSRect frame = screen.frame;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO
                                                         screen:screen];
        window.level = kCGDesktopWindowLevel;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorIgnoresCycle
            | NSWindowCollectionBehaviorFullScreenAuxiliary;
        window.opaque = YES;
        window.hasShadow = NO;
        window.ignoresMouseEvents = YES;
        window.backgroundColor = [NSColor blackColor];
        window.hidesOnDeactivate = NO;
        window.animationBehavior = NSWindowAnimationBehaviorNone;
        MatrixRainView *view = [[MatrixRainView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wordmark = NO;
        view.calm = NO;
        view.preferredFramesPerSecond = 30;
        view.cellHeight = RainCellHeight(frame.size.height);
        view.layer.contentsScale = screen.backingScaleFactor;
        [view syncDrawableToScreen];
        window.contentView = view;
        [window setFrame:screen.frame display:YES];
        [window orderBack:nil];
        [self.windows addObject:window];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && (strcmp(argv[1], "--snapshot") == 0 || strcmp(argv[1], "--snapshot-lock") == 0)) {
            BOOL wordmark = strcmp(argv[1], "--snapshot-lock") == 0;
            BOOL ok = [MatrixRainView writeSnapshotToURL:[NSURL fileURLWithPath:@(argv[2])]
                                                    size:CGSizeMake(2560, 1600)
                                                wordmark:wordmark];
            return ok ? 0 : 1;
        }
        [NSApplication sharedApplication];
        RainApp *app = [RainApp new];
        NSApp.delegate = app;
        [NSApp run];
    }
    return 0;
}
