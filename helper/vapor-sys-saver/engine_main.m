#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static void EngLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *path = @"/tmp/omacosy-vapor-engine.log";
    NSString *out = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [out writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *MIMEFor(NSString *ext) {
    ext = ext.lowercaseString;
    if ([ext isEqual:@"html"]) return @"text/html; charset=utf-8";
    if ([ext isEqual:@"js"]) return @"text/javascript; charset=utf-8";
    if ([ext isEqual:@"css"]) return @"text/css; charset=utf-8";
    if ([ext isEqual:@"wasm"]) return @"application/wasm";
    if ([ext isEqual:@"png"]) return @"image/png";
    return @"application/octet-stream";
}

@interface VaporEngine : NSObject <NSApplicationDelegate, WKNavigationDelegate>
@property (nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property (nonatomic, copy) NSURL *root;
@property int port;
@property int listenFD;
@property BOOL visible;
@property BOOL runNow;
@end

@implementation VaporEngine

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.windows = [NSMutableArray array];
    NSString *rootPath = [NSProcessInfo.processInfo.environment[@"OMACOSY_VAPOR_WEB"] copy]
        ?: [@"~/.local/share/omacosy/helper/vapor-sys-saver/web" stringByExpandingTildeInPath];
    self.root = [NSURL fileURLWithPath:rootPath isDirectory:YES];
    if (![self startHTTP]) {
        EngLog(@"http failed");
        return;
    }
    EngLog(@"http 127.0.0.1:%d root=%@", self.port, rootPath);
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(showOverlay) name:@"com.omacosy.vapor.show" object:nil];
    [dnc addObserver:self selector:@selector(showOverlay) name:@"com.apple.screensaver.didstart" object:nil];
    [dnc addObserver:self selector:@selector(hideOverlay) name:@"com.omacosy.vapor.hide" object:nil];
    [dnc addObserver:self selector:@selector(hideOverlay) name:@"com.apple.screensaver.didstop" object:nil];
    if (self.runNow) {
        [self showOverlay];
    }
}

- (BOOL)startHTTP {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    self.port = ntohs(addr.sin_port);
    if (listen(fd, 16) != 0) {
        close(fd);
        return NO;
    }
    self.listenFD = fd;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self acceptLoop];
    });
    return YES;
}

- (void)acceptLoop {
    while (self.listenFD >= 0) {
        int cfd = accept(self.listenFD, NULL, NULL);
        if (cfd < 0) {
            continue;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleClient:cfd];
        });
    }
}

- (void)handleClient:(int)fd {
    char buf[2048];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) {
        close(fd);
        return;
    }
    buf[n] = 0;
    NSString *req = [NSString stringWithUTF8String:buf];
    NSString *first = [req componentsSeparatedByString:@"\r\n"].firstObject;
    NSArray *parts = [first componentsSeparatedByString:@" "];
    NSString *path = parts.count > 1 ? parts[1] : @"/";
    if ([path isEqualToString:@"/"]) {
        path = @"/index.html";
    }
    path = [path componentsSeparatedByString:@"?"].firstObject;
    if ([path containsString:@".."]) {
        close(fd);
        return;
    }
    NSString *rel = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSString *file = [[self.root.path stringByAppendingPathComponent:rel] stringByStandardizingPath];
    if (![file hasPrefix:self.root.path]) {
        close(fd);
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (!data) {
        const char *miss = "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        send(fd, miss, strlen(miss), 0);
        close(fd);
        return;
    }
    NSString *mime = MIMEFor(file.pathExtension);
    NSString *head = [NSString stringWithFormat:
                      @"HTTP/1.0 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                      mime, (unsigned long)data.length];
    NSMutableData *out = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:data];
    send(fd, out.bytes, out.length, 0);
    close(fd);
}

- (void)showOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.visible) {
            return;
        }
        self.visible = YES;
        EngLog(@"show");
        [self rebuild];
    });
}

- (void)hideOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.visible = NO;
        EngLog(@"hide");
        for (NSWindow *w in self.windows) {
            [w orderOut:nil];
        }
        [self.windows removeAllObjects];
    });
}

- (void)rebuild {
    for (NSWindow *w in self.windows) {
        [w orderOut:nil];
    }
    [self.windows removeAllObjects];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.html", self.port]];
    for (NSScreen *screen in [NSScreen screens]) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO
                                                         screen:screen];
        window.level = NSScreenSaverWindowLevel + 2;
        window.opaque = YES;
        window.backgroundColor = NSColor.blackColor;
        window.ignoresMouseEvents = YES;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorIgnoresCycle
            | NSWindowCollectionBehaviorFullScreenAuxiliary;
        WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
        if (@available(macOS 11.0, *)) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
        }
        WKWebView *web = [[WKWebView alloc] initWithFrame:window.contentView.bounds configuration:cfg];
        web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        web.navigationDelegate = self;
        if (@available(macOS 12.0, *)) {
            web.underPageBackgroundColor = NSColor.blackColor;
        }
        window.contentView = web;
        [web loadRequest:[NSURLRequest requestWithURL:url]];
        [window orderFrontRegardless];
        [self.windows addObject:window];
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    EngLog(@"nav %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    EngLog(@"prov %@", error);
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        VaporEngine *engine = [VaporEngine new];
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--run") == 0) {
                engine.runNow = YES;
            }
        }
        NSApp.delegate = engine;
        [NSApp run];
    }
    return 0;
}
