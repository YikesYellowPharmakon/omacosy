// omacosy-ffm — focus follows mouse for the omacosy tiling setup.
// Event-driven: a global mouseMoved monitor (rides the Accessibility
// grant this binary needs anyway) hit-tests the topmost normal window
// under the cursor and focuses it via SLPS + the Accessibility API.
// Floats stay in front — a window covered by one is focused WITHOUT
// raise (kCPSNoWindows), and a parked cursor generates no events, so
// it can never steal focus from a launching window.
//
// Deliberately boring: no focus changes while any mouse button is down
// (drags deliver mouseDragged, not mouseMoved), a ~100ms dwell before
// a new window takes focus (no flicker when crossing windows), and
// only layer-0 windows count (menus, popups and the bar never steal
// focus).
import AppKit
import ApplicationServices

// Private SkyLight focus — the route AeroSpace and yabai use. The AX
// attributes politely no-op for some apps (Arc: every call returns
// success, nothing happens); SLPS actually moves focus.
struct PSN { var hi: UInt32 = 0, lo: UInt32 = 0 }
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout PSN) -> OSStatus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcess(_ psn: inout PSN, _ wid: UInt32, _ mode: UInt32) -> Int32
@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEvent(_ psn: inout PSN, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

let kCPSUserGenerated: UInt32 = 0x200
let kCPSNoWindows: UInt32 = 0x400

// `raise: false` — activate the process WITHOUT bringing its windows
// forward (kCPSNoWindows, yabai's focus-without-raise recipe). Plain
// activation reorders z on its own, so skipping only the AXRaise was
// not enough: the SLPS call itself was still lifting tiles over
// floating windows.
func slpsFocus(pid: pid_t, wid: UInt32, raise: Bool) {
    var psn = PSN()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    let mode = raise ? kCPSUserGenerated : kCPSUserGenerated | kCPSNoWindows
    _ = SLPSSetFrontProcess(&psn, wid, mode)
    var w = wid
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: &w) { src in
        for i in 0..<4 { bytes[0x3c + i] = src[i] }
    }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
    bytes[0x08] = 0x02
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
}

// Apps that hover must never focus (omarchy's JetBrains-style
// no_follow_mouse). One app name per line, # comments.
let ignoredApps: Set<String> = {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omacosy/ffm-ignore")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}()

// Event-driven: a global mouseMoved monitor replaces the old 80ms
// poll. "Focus follows mouse MOVEMENT, not hover position" (Hyprland
// semantics) is structural now — a stationary cursor produces no
// events, so it can never steal focus (a freshly launched window that
// self-activates under an idle pointer keeps its focus; the poll used
// to deactivate System Settings mid-launch and sink it behind the
// tiles). Drags are excluded for free too: dragging delivers
// mouseDragged, never mouseMoved.
let processMinInterval = 0.04 // hit-test at most ~25Hz during motion
let dwellSeconds = 0.10 // hover this long over a new window to focus it

var lastKey = ""
var pendingKey = ""
var lastFocusAt = 0.0
var lastProcessAt = 0.0
var dwellWork: DispatchWorkItem? = nil

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

typealias Cand = (pid: pid_t, num: Int, rect: CGRect, owner: String, blocking: Bool)

// Front-to-back layer-0 windows that pass the visibility filter.
// (Side effect vs the old single pass: an ignore-listed
// offscreen-stashed sliver no longer blocks focus — it's filtered
// before the ignore check, which is the behaviour we always wanted.)
func windowCandidates() -> [Cand] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return [] }
    let screens = displayBounds()
    var cands: [Cand] = []
    for w in list { // list is front-to-back
        guard let layer = w["kCGWindowLayer"] as? Int,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            let num = w["kCGWindowNumber"] as? Int
        else { continue }
        let owner = (w["kCGWindowOwnerName"] as? String) ?? ""
        // Windows ABOVE layer 0 are floating panels — 1Password's Touch
        // ID prompt sits at 101 — and hover-focus must not tunnel
        // through them to the tile underneath, which is precisely how
        // that prompt kept losing focus to whatever it covered. They
        // are not focus targets either, so they are carried as blockers:
        // hovering one leaves focus exactly where it is.
        //
        // Two things above layer 0 are emphatically NOT panels, and
        // treating them as such would freeze focus everywhere: our own
        // border overlay, which sits at layer 3 stretched over the
        // focused window, and the Window Server's own windows — the
        // CURSOR is one of them, at layer 2147483630, and it covers the
        // hit-test point by definition.
        let blocking = layer > 0
            && !owner.hasPrefix("omacosy-borders")
            && owner != "Window Server"
        guard layer == 0 || blocking else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        cands.append((pid, num, rect, owner, blocking))
    }
    return cands
}

func topWindowUnder(_ p: CGPoint, _ cands: [Cand]) -> (pid: pid_t, key: String, rect: CGRect, wid: UInt32, covered: Bool)? {
    for (i, c) in cands.enumerated() {
        guard c.rect.contains(p) else { continue }
        // a floating panel is under the cursor: same stance as the
        // ignore list — leave focus exactly where it is rather than
        // falling through to whatever it covers
        if c.blocking { return nil }
        // topmost window is ignore-listed: leave focus alone entirely
        // (don't fall through to the window beneath)
        if ignoredApps.contains(c.owner.lowercased()) { return nil }
        // Anything in front of the hit that overlaps it is a floating
        // window (tiles never overlap): raising the hit would drag it
        // over the float. The caller then focuses WITHOUT raise, which
        // is what keeps floats always-in-front, omarchy style. Sub-4px
        // overlaps don't count (border / shadow slop).
        let covered = cands[..<i].contains { f in
            let o = f.rect.intersection(c.rect)
            return !o.isNull && o.width > 4 && o.height > 4
        }
        return (c.pid, "\(c.pid):\(c.num)", c.rect, UInt32(c.num), covered)
    }
    return nil
}

// Focus exactly the window our filtered hit-test chose: find the AX
// window whose frame matches the CG rect. Never re-hit-test via AX —
// AXUIElementCopyElementAtPosition does its own unfiltered lookup and
// returns AeroSpace's offscreen-stashed slivers, causing focus loops.
let debug = ProcessInfo.processInfo.environment["OMACOSY_FFM_DEBUG"] != nil
func dbg(_ m: String) {
    if debug { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }
}

// `allowRaise: false` = the hovered window sits under a floating
// window somewhere on screen; focus it (SLPS + AXMain make it key)
// but leave z-order alone so the float stays in front — omarchy's
// float layer, emulated. Raising still happens when it's visually a
// no-op (nothing in front overlaps), which keeps the Chromium
// focus-needs-raise workaround for plain tile-to-tile hops.
func focus(pid: pid_t, rect: CGRect, allowRaise: Bool) {
    let app = AXUIElementCreateApplication(pid)
    // AX attribute reads are synchronous mach IPC with a ~6s default
    // timeout PER CALL — hovering a beachballing app froze the whole
    // daemon for (windows × attributes × 6s). Cap it hard.
    AXUIElementSetMessagingTimeout(app, 0.3)
    var matched = false
    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
        let wins = winsRef as? [AXUIElement] {
        for win in wins {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { continue }
            // These come from ANOTHER app's accessibility tree, so the
            // type is that app's word. Swift cannot check it for us —
            // a cast to a CoreFoundation type is unchecked and "always
            // succeeds" — so the type ID is checked by hand, and the
            // results are only used when AXValueGetValue says it filled
            // them in. Ignoring that return compared a zeroed point
            // against a real frame and silently never matched.
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard let posRef, let sizeRef,
                CFGetTypeID(posRef) == AXValueGetTypeID(),
                CFGetTypeID(sizeRef) == AXValueGetTypeID(),
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            else { continue }
            dbg("  ax win pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height))) vs cg=(\(Int(rect.origin.x)),\(Int(rect.origin.y))) \(Int(rect.width))x\(Int(rect.height))")
            if abs(pos.x - rect.origin.x) < 2, abs(pos.y - rect.origin.y) < 2,
                abs(size.width - rect.width) < 2, abs(size.height - rect.height) < 2 {
                // raise first — Chromium apps often ignore main/frontmost
                // without it; z-order changes are moot BETWEEN tiles
                // (they don't overlap), but skipped when a float is in
                // front (allowRaise == false)
                if allowRaise {
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                }
                let r = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                dbg("  -> matched, set main: \(r.rawValue)")
                matched = true
                break
            }
        }
    }
    // App-level activation raises the app's key window too, so it is
    // gated with the raise; the SLPS focus above already moved key
    // focus (it's the route that works even where AX no-ops).
    if allowRaise {
        let fr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        dbg("focus pid=\(pid) matched=\(matched) frontmost=\(fr.rawValue)")
    } else {
        dbg("focus pid=\(pid) matched=\(matched) no-raise (float in front)")
    }
}

if !AXIsProcessTrusted() {
    FileHandle.standardError.write("omacosy-ffm: waiting for Accessibility permission…\n".data(using: .utf8)!)
    // Do not call AXIsProcessTrustedWithOptions(prompt). Combined with
    // exit+KeepAlive after a grant, an ad-hoc rebuild shows a new
    // unchecked row and the dialog never stops.
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
}

// Shared by motion events and the dwell confirmation: hit-test the
// cursor and either focus (dwell confirmed) or arm the dwell timer.
// The timer path exists because events stop when the cursor stops —
// "glide into a window and rest" must still confirm ~100ms later.
let overlayFlag = "/tmp/omacosy-overlay-active-\(getuid())"

func process(confirmed: Bool) {
    // the workspace overview is up: it holds key focus deliberately,
    // and it floats above layer 0 so the hit-test would tunnel through
    // it and focus the tile underneath — stealing key out from under
    // the user's click. Stand down entirely.
    if FileManager.default.fileExists(atPath: overlayFlag) {
        pendingKey = ""
        return
    }
    // never move focus mid-drag (belt — mouseMoved doesn't fire then,
    // but the dwell timer can)
    if CGEventSource.buttonState(.combinedSessionState, button: .left)
        || CGEventSource.buttonState(.combinedSessionState, button: .right) {
        pendingKey = ""
        return
    }
    guard let e = CGEvent(source: nil) else { return }
    let cands = windowCandidates()
    guard let hit = topWindowUnder(e.location, cands) else {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    // judge "already focused" by reality, not our own bookkeeping — a
    // silently failed focus attempt must be retried, not remembered
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    if hit.pid == frontPid && hit.key == lastKey {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    let now = CFAbsoluteTimeGetCurrent()
    if confirmed, hit.key == pendingKey {
        // cooldown: never two focus changes within 250ms — breaks any
        // residual feedback loop with the window manager
        if now - lastFocusAt > 0.25 {
            // hover focus IS user intent (it's movement-gated), but it
            // emits no key/click CGEvent — stamp the focus guard's
            // intent file or a cross-monitor hover (focused-workspace
            // change) gets bounced as an "app yank", warping the
            // cursor back via aerospace's move-mouse hook
            FileManager.default.createFile(
                atPath: "/tmp/omacosy-user-intent-\(getuid())", contents: nil)
            slpsFocus(pid: hit.pid, wid: hit.wid, raise: !hit.covered)
            focus(pid: hit.pid, rect: hit.rect, allowRaise: !hit.covered)
            lastFocusAt = now
            lastKey = hit.key
        }
        pendingKey = ""
        return
    }
    if hit.key != pendingKey {
        pendingKey = hit.key
        dwellWork?.cancel()
        let work = DispatchWorkItem { process(confirmed: true) }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSeconds, execute: work)
    }
}

func trayAxCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

func trayAxChildren(_ el: AXUIElement) -> [AXUIElement] {
    (trayAxCopy(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func trayAxString(_ el: AXUIElement, _ attr: String) -> String {
    (trayAxCopy(el, attr) as? String) ?? ""
}

func trayCollectItems(_ el: AXUIElement, into out: inout [AXUIElement], depth: Int = 0) {
    if depth > 8 || out.count >= 80 { return }
    let role = trayAxString(el, kAXRoleAttribute as String)
    let ident = trayAxString(el, "AXIdentifier")
    if role == (kAXMenuBarItemRole as String) || role == "AXMenuBarItem"
        || ident.contains("menuextra") || ident.contains("notificationcenter") {
        out.append(el)
    }
    for child in trayAxChildren(el) { trayCollectItems(child, into: &out, depth: depth + 1) }
}

func trayClickExtra(bundle: String, needles: [String]) -> String {
    guard let pid = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == bundle })?
        .processIdentifier, pid != 0 else { return "no-app:\(bundle)" }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var items: [AXUIElement] = []
    for attr in ["AXExtrasMenuBar", kAXMenuBarAttribute as String] {
        if let ref = trayAxCopy(app, attr), CFGetTypeID(ref) == AXUIElementGetTypeID() {
            trayCollectItems(ref as! AXUIElement, into: &items)
        }
    }
    if let clock = items.first(where: { trayAxString($0, "AXIdentifier") == "com.apple.menuextra.clock" }) {
        let err = AXUIElementPerformAction(clock, kAXPressAction as CFString)
        return err == .success ? "ok:com.apple.menuextra.clock" : "press-fail:clock:\(err.rawValue)"
    }
    var seen: [String] = []
    for item in items {
        let ident = trayAxString(item, "AXIdentifier")
        let desc = !ident.isEmpty ? ident : [kAXDescriptionAttribute as String,
                    kAXTitleAttribute as String,
                    kAXRoleDescriptionAttribute as String]
            .map { trayAxString(item, $0) }
            .first { !$0.isEmpty } ?? ""
        seen.append(desc.isEmpty ? "?" : desc)
        if needles.contains(where: { desc.localizedCaseInsensitiveContains($0) }) {
            let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return err == .success ? "ok:\(desc)" : "press-fail:\(desc):\(err.rawValue)"
        }
    }
    return "miss items=\(items.count) seen=\(seen.joined(separator: "|"))"
}

func traylog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let path = "/tmp/omacosy-ffm.log"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path),
       let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

func handleTrayRequest() {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/omacosy/tray-cmd").path
    let raw = (try? String(contentsOfFile: path, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let kind = raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    guard ["controlcenter", "notifications"].contains(kind) else { return }
    let needles = kind == "notifications"
        ? ["Clock", "Notification Center", "Notification", "通知中心", "通知", "时钟"]
        : ["Control Center", "控制中心"]
    var result = "miss"
    for bundle in ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"] {
        result = trayClickExtra(bundle: bundle, needles: needles)
        if result.hasPrefix("ok:") || result.hasPrefix("press-fail:") { break }
        result = "\(bundle) \(result)"
    }
    traylog("tray \(kind) ax=\(AXIsProcessTrusted()) \(result)")
}

var trayWatch: (any DispatchSourceFileSystemObject)?

func watchTrayCmd() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/omacosy")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("tray-cmd").path
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { watchTrayCmd() }
        return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .attrib, .delete, .rename], queue: .main)
    src.setEventHandler {
        let ev = src.data
        handleTrayRequest()
        if ev.contains(.delete) || ev.contains(.rename) { src.cancel() }
    }
    src.setCancelHandler {
        close(fd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { watchTrayCmd() }
    }
    trayWatch = src
    src.resume()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var trailArmed = false
NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastProcessAt < processMinInterval {
        // trailing edge: a fast flick's FINAL event (the one actually
        // over the new window) can land inside the throttle window —
        // dropping it without a follow-up left the window unfocused
        // until the next twitch of the mouse
        if !trailArmed {
            trailArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + processMinInterval) {
                trailArmed = false
                lastProcessAt = CFAbsoluteTimeGetCurrent()
                process(confirmed: false)
            }
        }
        return
    }
    lastProcessAt = now
    process(confirmed: false)
}
watchTrayCmd()
app.run()
