import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit

/// Black out the top seam, pin Ghostty, and hide the pointer.
/// Cursor hide only works while THIS process owns the key window —
/// Ghostty in front keeps redrawing the system pointer. A clear
/// full-screen catcher sits above Ghostty, takes key, and hides it.
/// No event tap (that was the Allow sheet).

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("SLSMoveWindow")
func SLSMoveWindow(_ cid: Int32, _ wid: UInt32, _ point: UnsafePointer<CGPoint>) -> Int32

let catcherLevel = NSWindow.Level(rawValue: 1003)

final class CoverWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CatcherWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

final class CatcherView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) { hidePointer() }
    override func mouseEntered(with event: NSEvent) { hidePointer() }
    override func mouseDown(with event: NSEvent) { dismissFromInput() }
    override func rightMouseDown(with event: NSEvent) { dismissFromInput() }
    override func otherMouseDown(with event: NSEvent) { dismissFromInput() }
    override func keyDown(with event: NSEvent) { dismissFromInput() }
    override func scrollWheel(with event: NSEvent) { dismissFromInput() }
}

private var covers: [CoverWindow] = []
private var catchers: [CatcherWindow] = []
private var cursorHidden = false
private var sawSaver = false
private let startedAt = Date()

private func blankCursor() -> NSCursor {
    let img = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
        NSColor.clear.setFill()
        rect.fill()
        return true
    }
    return NSCursor(image: img, hotSpot: .zero)
}

private func hidePointer() {
    blankCursor().set()
    if !cursorHidden {
        NSCursor.hide()
        cursorHidden = true
    }
    for _ in 0..<4 { CGDisplayHideCursor(CGMainDisplayID()) }
    CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
}

private func showPointer() {
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    if cursorHidden {
        NSCursor.unhide()
        cursorHidden = false
    }
    CGDisplayShowCursor(CGMainDisplayID())
    NSCursor.arrow.set()
}

private func showCovers() {
    let screens = NSScreen.screens
    if covers.count == screens.count {
        for (i, screen) in screens.enumerated() {
            if covers[i].frame != screen.frame {
                covers[i].setFrame(screen.frame, display: true)
            }
            covers[i].orderFrontRegardless()
        }
        return
    }
    covers.forEach { $0.orderOut(nil) }
    covers.removeAll()
    for screen in screens {
        let win = CoverWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.animationBehavior = .none
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: -1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.setFrame(screen.frame, display: true)
        win.orderFrontRegardless()
        covers.append(win)
    }
}

private func showCatchers() {
    let screens = NSScreen.screens
    if catchers.count == screens.count {
        for (i, screen) in screens.enumerated() {
            if catchers[i].frame != screen.frame {
                catchers[i].setFrame(screen.frame, display: true)
            }
            catchers[i].orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        catchers.first?.makeKeyAndOrderFront(nil)
        hidePointer()
        return
    }
    catchers.forEach { $0.orderOut(nil) }
    catchers.removeAll()
    for screen in screens {
        let win = CatcherWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.animationBehavior = .none
        win.ignoresMouseEvents = false
        win.level = catcherLevel
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.setFrame(screen.frame, display: true)
        let view = CatcherView(frame: NSRect(origin: .zero, size: screen.frame.size))
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        catchers.append(win)
    }
    NSApp.activate(ignoringOtherApps: true)
    catchers.first?.makeKeyAndOrderFront(nil)
    catchers.first?.makeFirstResponder(catchers.first?.contentView)
    hidePointer()
}

private func processCommand(_ pid: pid_t) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-p", "\(pid)", "-ww", "-o", "command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

private func axPin(pid: pid_t, display: CGRect) {
    guard AXIsProcessTrusted() else { return }
    let appEl = AXUIElementCreateApplication(pid)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement] else { return }
    for win in wins {
        var pos = CGPoint(x: display.minX, y: display.minY)
        var size = CGSize(width: display.width, height: display.height)
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        }
    }
}

private func saverStillUp() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return omacosyScreensaverProcessVisible(in: text)
}

private func omacosyScreensaverProcessVisible(in text: String) -> Bool {
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = String(raw)
        if line.contains("omacosy-screensaver-idle") { continue }
        if line.contains("omacosy-launch-screensaver") { continue }
        if line.contains("ghostty-screensaver.conf") { return true }
        if line.range(of: #"/omacosy-screensaver(?:\s|$)"#, options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

private func pkill(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

private func killSaver() {
    pkill(["-f", "ghostty.*ghostty-screensaver.conf"])
    pkill(["-f", "/bin/omacosy-screensaver$"])
    pkill(["-x", "ttfx"])
    pkill(["-x", "tte"])
}

private func teardown() {
    catchers.forEach { $0.orderOut(nil) }
    catchers.removeAll()
    covers.forEach { $0.orderOut(nil) }
    covers.removeAll()
    showPointer()
}

private func lockNow() {
    guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
          let sym = dlsym(h, "SACLockScreenImmediate") else { return }
    typealias LockFn = @convention(c) () -> Int32
    _ = unsafeBitCast(sym, to: LockFn.self)()
}

private func finish(lock: Bool) {
    if lock { lockNow() }
    killSaver()
    teardown()
    CFRunLoopStop(CFRunLoopGetMain())
    exit(0)
}

private func dismissFromInput() {
    if sawSaver { finish(lock: true) }
}

private func hidIdle() -> Double {
    var idle: UInt64 = 0
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    if service != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any],
           let num = dict["HIDIdleTime"] as? UInt64 {
            idle = num
        }
        IOObjectRelease(service)
    }
    return Double(idle) / 1_000_000_000.0
}

private func pinSaver() {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return }
    let display = CGDisplayBounds(CGMainDisplayID())
    var pids: Set<pid_t> = []
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "Ghostty",
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let n = w[kCGWindowNumber as String] as? Int
        else { continue }
        let cmd = processCommand(pid)
        guard cmd.contains("ghostty-screensaver.conf") || cmd.contains("omacosy-screensaver")
        else { continue }
        pids.insert(pid)
        var origin = CGPoint(x: display.minX, y: display.minY)
        _ = SLSMoveWindow(SLSMainConnectionID(), UInt32(n), &origin)
        _ = n
    }
    for pid in pids {
        axPin(pid: pid, display: display)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

_ = NSEvent.addLocalMonitorForEvents(matching: [
    .keyDown, .flagsChanged,
    .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
]) { event in
    if sawSaver { dismissFromInput() }
    return event
}

var armedAt: Date?
var lastIdle = hidIdle()

Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
    if saverStillUp() {
        if !sawSaver {
            sawSaver = true
            armedAt = Date()
            lastIdle = hidIdle()
        }
        showCovers()
        pinSaver()
        showCatchers()
        hidePointer()
        if let armed = armedAt, Date().timeIntervalSince(armed) >= 0.45 {
            let now = hidIdle()
            if now + 0.03 < lastIdle || now < 0.05 {
                finish(lock: true)
            }
            lastIdle = now
        }
        return
    }
    if sawSaver {
        finish(lock: true)
    }
    if Date().timeIntervalSince(startedAt) > 6 {
        finish(lock: false)
    }
}

signal(SIGTERM) { _ in
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    CGDisplayShowCursor(CGMainDisplayID())
    exit(0)
}

app.run()
teardown()
exit(0)
