// omacosy-tray — click Control Center / Notification Center extras.
// Signed as omacosy-ffm so it can ride the existing Accessibility grant.
// Must be started by launchd (WatchPaths), never as a child of the bar:
// a bar-spawned process inherits the bar's TCC identity and ax=false.
import AppKit
import ApplicationServices

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axCopy(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func axString(_ el: AXUIElement, _ attr: String) -> String {
    (axCopy(el, attr) as? String) ?? ""
}

func collectItems(_ el: AXUIElement, into out: inout [AXUIElement]) {
    let role = axString(el, kAXRoleAttribute as String)
    if role == (kAXMenuBarItemRole as String) || role == "AXMenuBarItem" {
        out.append(el)
    }
    for c in axChildren(el) { collectItems(c, into: &out) }
}

func clickExtra(bundle: String, needles: [String]) -> String {
    guard let pid = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == bundle })?
        .processIdentifier, pid != 0 else { return "no-app:\(bundle)" }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var items: [AXUIElement] = []
    for attr in ["AXExtrasMenuBar", kAXMenuBarAttribute as String] {
        if let ref = axCopy(app, attr), CFGetTypeID(ref) == AXUIElementGetTypeID() {
            collectItems(ref as! AXUIElement, into: &items)
        }
    }
    var seen: [String] = []
    for item in items {
        let desc = [kAXDescriptionAttribute as String,
                    kAXTitleAttribute as String,
                    kAXRoleDescriptionAttribute as String]
            .map { axString(item, $0) }
            .first { !$0.isEmpty } ?? ""
        seen.append(desc.isEmpty ? "?" : desc)
        if needles.contains(where: { desc.localizedCaseInsensitiveContains($0) }) {
            let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return err == .success ? "ok:\(desc)" : "press-fail:\(desc):\(err.rawValue)"
        }
    }
    return "miss items=\(items.count) seen=\(seen.joined(separator: "|"))"
}

func cmdPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/omacosy/tray-cmd").path
}

func commandKind() -> String {
    if let arg = CommandLine.arguments.dropFirst().first,
       ["controlcenter", "notifications"].contains(arg) {
        return arg
    }
    let raw = (try? String(contentsOfFile: cmdPath(), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
}

func runClick(_ kind: String) -> String {
    let needles = kind == "notifications"
        ? ["Clock", "Notification", "通知", "时钟"]
        : ["Control Center", "控制中心"]
    var result = clickExtra(bundle: "com.apple.controlcenter", needles: needles)
    if result.hasPrefix("miss") || result.hasPrefix("no-app") {
        let other = clickExtra(bundle: "com.apple.systemuiserver", needles: needles)
        if !other.hasPrefix("miss") && !other.hasPrefix("no-app") { result = other }
    }
    return result
}

func logLine(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let path = "/tmp/omacosy-tray.log"
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

func watchLoop() {
    let path = cmdPath()
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    var last = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    logLine("watch start ax=\(AXIsProcessTrusted()) pid=\(getpid())")
    while true {
        let cur = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if cur != last {
            last = cur
            let kind = commandKind()
            if ["controlcenter", "notifications"].contains(kind) {
                let result = runClick(kind)
                logLine("ax=\(AXIsProcessTrusted()) \(kind) \(result)")
            }
        }
        Thread.sleep(forTimeInterval: 0.12)
    }
}

func ensureWatch() {
    let pidfile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/omacosy/tray-watch.pid").path
    if let raw = try? String(contentsOfFile: pidfile, encoding: .utf8),
       let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid != getpid(),
       kill(pid, 0) == 0 {
        exit(0)
    }
    try? "\(getpid())".write(toFile: pidfile, atomically: true, encoding: .utf8)
    watchLoop()
}

let args = Set(CommandLine.arguments.dropFirst())
if args.contains("--ensure-watch") || args.contains("--watch") {
    ensureWatch()
}

let kind = commandKind()
guard ["controlcenter", "notifications"].contains(kind) else { exit(0) }
let result = runClick(kind)
fputs("ax=\(AXIsProcessTrusted()) \(kind) \(result)\n", stdout)
exit(result.hasPrefix("ok:") ? 0 : 1)
