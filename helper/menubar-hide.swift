// Permanently hide the native menu bar so it cannot stack on top of
// the omacosy bar. macOS has no supported "never show" pref; autohide
// still reveals on the top edge. This forces SkyLight alpha to 0 and
// reapplies it if SystemUIServer tries to peek.
//
// Exception: macOS native fullscreen parks the traffic lights IN the
// menu bar. Releasing the bury there lets the auto-hidden menu bar
// slide in on hover so the buttons are reachable. AeroSpace fullscreen
// (Super+F) is not native — keep the menu bar buried and order it
// behind the window so the 24px layer does not leave a black seam.
import AppKit
import ApplicationServices

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("SLSSetMenuBarInsetAndAlpha")
func SLSSetMenuBarInsetAndAlpha(_ cid: Int32, _ unused1: Double, _ unused2: Double, _ alpha: Float) -> Int32

@_silgen_name("SLSSetMenuBarAutohideEnabled")
func SLSSetMenuBarAutohideEnabled(_ cid: Int32, _ enabled: Bool) -> Int32

@_silgen_name("SLSSetMenuBarSystemOverrideAlpha")
func SLSSetMenuBarSystemOverrideAlpha(_ cid: Int32, _ alpha: Float) -> Int32

@_silgen_name("SLSSetMenuBarVisibilityOverrideOnDisplay")
func SLSSetMenuBarVisibilityOverrideOnDisplay(_ cid: Int32, _ display: UInt32, _ hidden: Bool) -> Int32

@_silgen_name("SLSSetWindowAlpha")
func SLSSetWindowAlpha(_ cid: Int32, _ wid: UInt32, _ alpha: Float) -> Int32

@_silgen_name("SLSOrderWindow")
func SLSOrderWindow(_ cid: Int32, _ wid: UInt32, _ mode: Int32, _ relative: UInt32) -> Int32

let kCGSOrderBelow: Int32 = -1
let kCGSOrderAbove: Int32 = 1

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func aerospaceBin() -> String {
    ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? "/opt/homebrew/bin/aerospace"
}

func aerospaceLayout() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: aerospaceBin())
    p.arguments = ["list-windows", "--focused", "--format", "%{window-layout}"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func displays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return Array(ids.prefix(Int(n)))
}

func menubarWindowIDs() -> [UInt32] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    var ids: [UInt32] = []
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "Window Server",
              (w[kCGWindowName as String] as? String) == "Menubar",
              let n = w[kCGWindowNumber as String] as? Int else { continue }
        ids.append(UInt32(n))
    }
    return ids
}

func axNativeFullscreen() -> Bool? {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier != "com.omacosy.bar" else { return false }
    let axApp = AXUIElementCreateApplication(front.processIdentifier)
    var axWin: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &axWin) == .success,
          let axWin, CFGetTypeID(axWin) == AXUIElementGetTypeID() else { return nil }
    var fs: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWin as! AXUIElement, "AXFullScreen" as CFString, &fs) == .success
    else { return nil }
    return fs as? Bool
}

var ssCheckedAt = Date.distantPast
var ssCached = false
func screensaverRunning() -> Bool {
    if Date().timeIntervalSince(ssCheckedAt) < 0.25 { return ssCached }
    ssCheckedAt = Date()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else {
        ssCached = false
        return false
    }
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    ssCached = omacosyScreensaverProcessVisible(in: text)
    return ssCached
}

func omacosyScreensaverProcessVisible(in text: String) -> Bool {
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

func geometricFullscreen() -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier != "com.omacosy.bar" else { return false }
    let pid = front.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                          width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        for d in displays() {
            let bounds = CGDisplayBounds(d)
            guard bounds.intersects(rect) else { continue }
            if rect.width >= bounds.width - 4,
               rect.minY - bounds.minY < 30,
               rect.height >= bounds.height - 36 {
                return true
            }
        }
    }
    return false
}

var nativeCheckedAt = Date.distantPast
var nativeCached = false
func focusedIsNativeFullscreen() -> Bool {
    if Date().timeIntervalSince(nativeCheckedAt) < 0.25 { return nativeCached }
    nativeCheckedAt = Date()
    if let ax = axNativeFullscreen() {
        nativeCached = ax
    } else {
        nativeCached = aerospaceLayout() == "macos_native_fullscreen"
    }
    return nativeCached
}

func releaseNativeMenuBar() {
    let cid = SLSMainConnectionID()
    _ = SLSSetMenuBarAutohideEnabled(cid, true)
    _ = SLSSetMenuBarSystemOverrideAlpha(cid, 1)
    _ = SLSSetMenuBarInsetAndAlpha(cid, 0, 1, 1)
    for d in displays() {
        _ = SLSSetMenuBarVisibilityOverrideOnDisplay(cid, d, false)
    }
    for wid in menubarWindowIDs() {
        _ = SLSSetWindowAlpha(cid, wid, 1)
        _ = SLSOrderWindow(cid, wid, kCGSOrderAbove, 0)
    }
}

func buryNativeMenuBar() {
    let cid = SLSMainConnectionID()
    _ = SLSSetMenuBarAutohideEnabled(cid, true)
    _ = SLSSetMenuBarSystemOverrideAlpha(cid, 0)
    _ = SLSSetMenuBarInsetAndAlpha(cid, 0, 1, 0)
    for d in displays() {
        _ = SLSSetMenuBarVisibilityOverrideOnDisplay(cid, d, true)
    }
    let coverSeam = geometricFullscreen() || screensaverRunning()
    for wid in menubarWindowIDs() {
        _ = SLSSetWindowAlpha(cid, wid, 0)
        _ = SLSOrderWindow(cid, wid, coverSeam ? kCGSOrderBelow : kCGSOrderAbove, 0)
    }
}

func syncMenuBar() {
    if focusedIsNativeFullscreen() {
        releaseNativeMenuBar()
    } else {
        buryNativeMenuBar()
    }
}

syncMenuBar()
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in syncMenuBar() }
_ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
    let p = NSEvent.mouseLocation
    if NSScreen.screens.contains(where: {
        $0.frame.insetBy(dx: 0, dy: -2).contains(p) && $0.frame.maxY - p.y <= 10
    }) {
        syncMenuBar()
    }
}
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { _ in syncMenuBar() }
app.run()
