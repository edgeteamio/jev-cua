import AppKit
import ApplicationServices
import Foundation
import JevCore
import os

/// Thin accessibility helpers. Every function is synchronous and bounded; callers run them off
/// the main thread. Messaging timeouts keep a hung app from stalling a decision (tiptour).
public enum AX {
    static let messagingTimeout: Float = 0.3
    nonisolated(unsafe) static var callCount = 0   // per-snapshot accounting, reset by perception
    private static let prepared = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    public static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        let first = prepared.withLock { $0.insert(pid).inserted }
        if first {
            AXUIElementSetMessagingTimeout(el, messagingTimeout)
            // Electron exposes its tree only after this is set on the application element; Chromium
            // wants the enhanced-UI flag. Both are no-ops elsewhere (plan section 5).
            AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return el
    }

    public static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        callCount += 1
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    public static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    public static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (attr(el, name) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func frame(_ el: AXUIElement) -> Frame? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return Frame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        callCount += 1
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    static func setValue(_ el: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    public static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// Bounded breadth-first search for the first element matching `predicate`.
    /// `skipInto` names roles whose subtrees are not entered: a browser's web area is thousands of
    /// nodes wide and swamps a breadth-first search for chrome (the tab strip, the toolbar).
    public static func find(in root: AXUIElement, maxNodes: Int = 600, maxDepth: Int = 12, skipInto: Set<String> = [], where predicate: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if predicate(el, role) { return el }
            if depth < maxDepth, role != kAXMenuBarRole, role != kAXMenuRole, !skipInto.contains(role) {
                for c in children(el) { queue.append((c, depth + 1)) }
            }
        }
        return nil
    }

    static func normalizeRole(_ role: String, subrole: String?) -> String {
        switch (role, subrole) {
        case (_, "AXSecureTextField"): return "securetextfield"
        case (_, "AXSearchField"): return "searchfield"
        case ("AXTextField", _): return "textfield"
        case ("AXTextArea", _): return "textarea"
        case ("AXComboBox", _): return "combobox"
        case ("AXButton", _): return "button"
        case ("AXLink", _): return "link"
        case ("AXCheckBox", _): return "checkbox"
        case ("AXRadioButton", _): return "radio"
        case ("AXPopUpButton", _): return "popupbutton"
        case ("AXMenuItem", _): return "menuitem"
        case ("AXRow", _): return "row"
        case ("AXCell", _): return "cell"
        case ("AXTabGroup", _): return "tabgroup"
        case ("AXStaticText", _): return "statictext"
        case ("AXWebArea", _): return "webarea"
        case ("AXImage", _): return "image"
        default: return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
        }
    }

    static let editableRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox", "securetextfield"]

    /// A menu item by menu title and item title, without opening the menu (AXPress works on
    /// menu items directly). Titles compared case-insensitively, trailing "…" ignored.
    static func menuItem(pid: pid_t, menu: String, item: String) -> AXUIElement? {
        guard let bar = element(app(pid), kAXMenuBarAttribute) else { return nil }
        func norm(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces).lowercased() }
        guard let top = children(bar).first(where: { norm(string($0, kAXTitleAttribute)) == menu.lowercased() }) else { return nil }
        for m in children(top) {   // the AXMenu under the bar item
            if let hit = children(m).first(where: { norm(string($0, kAXTitleAttribute)) == norm(item) }) { return hit }
        }
        return nil
    }

    static func focusedField(pid: pid_t) -> FocusedField? {
        let app = Self.app(pid)
        guard let el = element(app, kAXFocusedUIElementAttribute) else { return nil }
        let role = normalizeRole(string(el, kAXRoleAttribute) ?? "", subrole: string(el, kAXSubroleAttribute))
        guard editableRoles.contains(role) || (bool(el, "AXEditable") ?? false) else { return nil }
        let value = string(el, kAXValueAttribute)
        return FocusedField(role: role, label: string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute),
                            placeholder: string(el, kAXPlaceholderValueAttribute), valuePreview: value.map { String($0.prefix(80)) },
                            secure: role == "securetextfield")
    }

    /// Vertical scroll position (0 top … 1 bottom) of the innermost scroll area under `window`
    /// that contains `point`, via its AXVerticalScrollBar's AXValue; nil when none is exposed
    /// (Chrome's web content, for one).
    static func scrollPosition(window: AXUIElement, at point: CGPoint) -> Double? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var best: (depth: Int, value: Double)?
        while !queue.isEmpty, visited < 300 {
            let (el, depth) = queue.removeFirst(); visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXScrollAreaRole, let f = AX.frame(el),
               point.x >= f.x, point.x <= f.x + f.width, point.y >= f.y, point.y <= f.y + f.height,
               let bar = AX.element(el, kAXVerticalScrollBarAttribute), let v = AX.attr(bar, kAXValueAttribute) as? NSNumber {
                if best == nil || depth > best!.depth { best = (depth, v.doubleValue) }
            }
            if depth < 8, role != kAXMenuBarRole { for c in AX.children(el) { queue.append((c, depth + 1)) } }
        }
        return best?.value
    }

    static func focusedValue(pid: pid_t) -> String? {
        let app = Self.app(pid)
        guard let el = element(app, kAXFocusedUIElementAttribute) else { return nil }
        return string(el, kAXValueAttribute)
    }

    /// Open browser tabs in the front window: the radio buttons under its tab group. A count only;
    /// tab titles are never read into state (plan section 5).
    /// A menu item's keyboard shortcut, as the menu bar shows it: the virtual key when the app
    /// gives one, else the command character mapped to a key; modifiers from AXMenuItemCmdModifiers
    /// (1 shift, 2 option, 4 control, 8 = no command key). Nil when the item has no shortcut.
    public static func menuShortcut(_ item: AXUIElement) -> (keyCode: CGKeyCode, flags: CGEventFlags, label: String)? {
        let mods = (attr(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        var flags: CGEventFlags = (mods & 8) == 0 ? [.maskCommand] : []
        if mods & 1 != 0 { flags.insert(.maskShift) }
        if mods & 2 != 0 { flags.insert(.maskAlternate) }
        if mods & 4 != 0 { flags.insert(.maskControl) }
        let char = (attr(item, "AXMenuItemCmdChar") as? String) ?? ""
        var code: CGKeyCode? = (attr(item, "AXMenuItemCmdVirtualKey") as? NSNumber).map { CGKeyCode($0.intValue) }
        if code == nil, let ch = char.lowercased().first { code = Keys.keyCode(for: ch) }
        guard let code, !(char.isEmpty && (attr(item, "AXMenuItemCmdVirtualKey") as? NSNumber) == nil) else { return nil }
        let label = (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "") + (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "") + char.uppercased()
        return (code, flags, label)
    }

    public static func tabStrip(pid: pid_t) -> AXUIElement? {
        guard let win = focusedWindow(Self.app(pid)) else { return nil }
        return find(in: win, maxNodes: 1200, maxDepth: 10, skipInto: ["AXWebArea"], where: { _, role in role == kAXTabGroupRole })
    }

    /// Open tabs in a strip found by `tabStrip`: every tab button under it, through Chrome's own
    /// tab groups (inner tab groups), where a new tab lands when the active tab is in one.
    public static func tabCount(strip: AXUIElement) -> Int {
        var n = 0
        var queue: [(AXUIElement, Int)] = [(strip, 0)]
        while let (el, depth) = queue.popLast() {
            for c in children(el) {
                let role = string(c, kAXRoleAttribute) ?? ""
                if role == kAXRadioButtonRole { n += 1 }
                else if role == kAXTabGroupRole, depth < 3 { queue.append((c, depth + 1)) }
            }
        }
        return n
    }

    public static func windowCount(pid: pid_t) -> Int {
        (attr(Self.app(pid), kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
    }

    public static func focusedElement(pid: pid_t) -> AXUIElement? {
        element(Self.app(pid), kAXFocusedUIElementAttribute)
    }

    /// Selects `range` (UTF-16 units, as AX text ranges are) in a text element so the next
    /// keystrokes overwrite it; false when the app does not take the attribute (Chrome's web
    /// content, for one). The set call returns before some apps apply it (Notes, 2026-09-20:
    /// keystrokes sent right after landed at the old caret), so callers confirm with
    /// `selectedRange` before typing.
    public static func selectText(_ el: AXUIElement, range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    public static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    public static func selectedRange(_ el: AXUIElement) -> CFRange? {
        guard let r = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(r as! AXValue, .cfRange, &range) ? range : nil
    }
}

/// Frontmost application. Read live through the Accessibility system-wide element: NSWorkspace's
/// `frontmostApplication` only updates when the main run loop pumps, so a command-line process
/// (`say`) would keep reporting the app that was in front when it started. Falls back to
/// NSWorkspace when Accessibility is not granted.
public enum Apps {
    nonisolated(unsafe) private static let systemWide = AXUIElementCreateSystemWide()

    public static func frontmost() -> AppIdentity {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(v as! AXUIElement, &pid) == .success, pid > 0, let a = NSRunningApplication(processIdentifier: pid) {
                return AppIdentity(name: a.localizedName ?? "?", bundleId: a.bundleIdentifier ?? "", pid: pid)
            }
        }
        if let a = NSWorkspace.shared.frontmostApplication {
            return AppIdentity(name: a.localizedName ?? "?", bundleId: a.bundleIdentifier ?? "", pid: a.processIdentifier)
        }
        return AppIdentity(name: "?", bundleId: "", pid: 0)
    }

    static func running(bundleId: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    public static func url(bundleId: String, name: String) -> URL? {
        if !bundleId.isEmpty, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return u }
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", "/System/Applications/Utilities"] {
            let u = URL(fileURLWithPath: dir).appending(path: name + ".app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Activates (launching if needed). Returns when the request was accepted, not when frontmost.
    public static func activate(bundleId: String, name: String) async -> Bool {
        guard let url = url(bundleId: bundleId, name: name) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg); return true } catch { return false }
    }

    public static func open(url: URL, inAppAt appURL: URL?) async -> Bool {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            if let appURL { _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) }
            else { _ = try await NSWorkspace.shared.open(url, configuration: cfg) }
            return true
        } catch { return false }
    }
}

/// Browser helpers: the front tab's URL through the address bar or the web area's AXURL.
public enum Browser {
    static let bundleIds = Config.browserBundleIds
    static func isBrowser(_ bundleId: String) -> Bool { bundleIds.contains(bundleId) }

    /// Chrome's profile picker ("Who's using Chrome?") is its key window while it is open: new-tab
    /// and close-tab then do nothing anywhere, while AX still reports the browser window as focused
    /// (the sessions Chrome case, 2026-09-22 and 2026-09-28). Found by its title, read locally.
    public static func profilePickerOpen(pid: pid_t) -> Bool {
        let windows = (AX.attr(AX.app(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.contains { (AX.string($0, kAXTitleAttribute) ?? "").lowercased().contains("using chrome") }
    }
    public static let profilePickerDetail = "Chrome's profile picker is open: close it and try again"

    /// Waits for the front tab's page to settle after a navigation: the web area reports
    /// AXLoaded, or its child count holds still across two reads. Bounded.
    static func waitForLoad(pid: pid_t, timeoutMs: Int = 2500) async {
        let deadline = Mono.now() + Double(timeoutMs) / 1000
        var lastCount = -1
        var stableReads = 0
        while Mono.now() < deadline {
            if let web = webArea(pid: pid) {
                // AXLoaded reports the previous page as loaded right after a navigation starts, so the
                // settle test is the child count holding still across two reads.
                let count = AX.children(web).count
                if count > 0, count == lastCount { stableReads += 1; if stableReads >= 2 { return } } else { stableReads = 0 }
                lastCount = count
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// A digest of the page's visible text, for "did the page change in place" evidence. Same
    /// reader as `pageTexts`, so what the evidence check sees is what the digest saw.
    static func pageTextDigest(pid: pid_t) -> Int {
        var hasher = Hasher()
        for t in pageTexts(pid: pid) { hasher.combine(t) }
        return hasher.finalize()
    }

    /// The front tab's web area. A wide search: Chrome's tab strip and toolbar can hold hundreds
    /// of nodes before the page, and a search that gives up early reads an empty page.
    public static func webArea(pid: pid_t) -> AXUIElement? {
        guard let win = AX.focusedWindow(AX.app(pid)) else { return nil }
        return AX.find(in: win, maxNodes: 2000, maxDepth: 12, where: { _, role in role == "AXWebArea" })
    }

    /// The page's visible texts (static texts and field values), for evidence checks in the suite.
    public static func pageTexts(pid: pid_t, maxNodes: Int = 800) -> [String] {
        guard let web = webArea(pid: pid) else { return [] }
        var out: [String] = []
        var queue: [(AXUIElement, Int)] = [(web, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (el, depth) = queue.removeFirst(); visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole || role == kAXTextFieldRole || role == kAXTextAreaRole, let v = AX.string(el, kAXValueAttribute), !v.isEmpty { out.append(v) }
            if depth < 12 { for c in AX.children(el) { queue.append((c, depth + 1)) } }
        }
        return out
    }

    /// The committed document URL (the web area's AXURL), which lags the address bar's typed
    /// text until a navigation actually commits. Nil when the web area exposes none.
    /// Text fields on the page by label (title, description, or placeholder) with their values.
    public static func fieldValues(pid: pid_t, maxNodes: Int = 800) -> [String: String] {
        guard let web = webArea(pid: pid) else { return [:] }
        var out: [String: String] = [:]
        var queue: [(AXUIElement, Int)] = [(web, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (el, depth) = queue.removeFirst(); visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXTextFieldRole || role == kAXTextAreaRole {
                let label = (AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXPlaceholderValueAttribute) ?? "").trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { out[label] = AX.string(el, kAXValueAttribute) ?? "" }
            }
            if depth < 12 { for c in AX.children(el) { queue.append((c, depth + 1)) } }
        }
        return out
    }

    /// The focused element's full value in any app (the suite's evidence reads beyond the preview).
    public static func focusedValue(pid: pid_t) -> String? { AX.focusedValue(pid: pid) }

    /// Reloads the front tab (Cmd+R) and waits for it to settle; the suite's per-run reset.
    public static func reload(pid: pid_t) async {
        Keys.press(Keys.rKey, flags: .maskCommand, pid: pid)
        try? await Task.sleep(for: .milliseconds(300))
        await waitForLoad(pid: pid)
    }

    public static func documentURL(pid: pid_t) -> String? {
        guard let web = webArea(pid: pid) else { return nil }
        for name in ["AXURL", kAXURLAttribute, kAXDocumentAttribute] {
            guard let v = AX.attr(web, name) else { continue }
            if let u = v as? URL { return u.absoluteString }
            if let u = v as? NSURL { return u.absoluteString }
            if let s = v as? String, !s.isEmpty { return s }
        }
        return nil
    }

    public static func currentURL(pid: pid_t) -> String? {
        let app = AX.app(pid)
        guard let win = AX.focusedWindow(app) else { return nil }
        if let field = AX.find(in: win, maxNodes: 500, maxDepth: 10, where: { el, role in
            guard role == kAXTextFieldRole else { return false }
            let label = [AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXTitleAttribute)].compactMap { $0 }.joined(separator: " ")
            return label.localizedCaseInsensitiveContains("address")
        }), let v = AX.string(field, kAXValueAttribute), !v.isEmpty { return v.contains("://") ? v : "https://" + v }
        return documentURL(pid: pid)
    }
}

/// Synthetic input through CGEvent. `postToPid` targets the app directly so the cursor never moves.
public enum Keys {
    public static func press(_ keyCode: CGKeyCode, flags: CGEventFlags = [], pid: pid_t? = nil) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        if let pid { down.postToPid(pid); up.postToPid(pid) } else { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
    }

    static let returnKey: CGKeyCode = 36
    static let escapeKey: CGKeyCode = 53
    static let nKey: CGKeyCode = 45
    static let leftBracketKey: CGKeyCode = 33
    static let lKey: CGKeyCode = 37
    static let rKey: CGKeyCode = 15
    /// ANSI keycodes for the characters a menu shortcut can name.
    public static func keyCode(for ch: Character) -> CGKeyCode? {
        let table: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
                                             "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
                                             "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
                                             "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\r": 36, "\t": 48]
        return table[ch]
    }

    public static let aKey: CGKeyCode = 0
    public static let upArrowKey: CGKeyCode = 126
    public static let rightArrowKey: CGKeyCode = 124

    /// Types Unicode text as keystroke events, in short chunks.
    static func type(_ text: String, pid: pid_t? = nil) async {
        for chunk in text.chunked(20) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            let units = Array(chunk.utf16)
            units.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            units.withUnsafeBufferPointer { up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            if let pid { down.postToPid(pid); up.postToPid(pid) } else { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// A synthetic left click at a screen point (HID tap: moves the cursor). Fallback only. A
    /// move precedes the press and both events carry click count 1, without which web pages and
    /// many controls do not treat the pair as a click.
    static func click(at point: CGPoint) {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
    }

    /// Scroll wheel at a screen point. Posted through the HID tap: a wheel event posted straight
    /// to a pid is not routed to a window (Chrome, Electron, and Sublime all ignored it on
    /// 2026-09-20). The event's location targets the window under the point; the visible cursor
    /// does not move. Several small ticks scroll like a wheel; one big tick is often clamped.
    public static func scroll(lines: Int, at point: CGPoint) {
        let direction: Int32 = lines < 0 ? 1 : -1
        var remaining = abs(lines)
        while remaining > 0 {
            let step = min(3, remaining)
            guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: direction * Int32(step), wheel2: 0, wheel3: 0) else { return }
            ev.location = point
            ev.post(tap: .cghidEventTap)
            remaining -= step
            usleep(12_000)
        }
    }

}

extension String {
    func chunked(_ size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in self { current.append(ch); if current.count >= size { out.append(current); current = "" } }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Polls `condition` every `everyMs` until it returns a value or `timeoutMs` passes (plan section 11 settle waits).
func waitFor<T>(timeoutMs: Int, everyMs: Int = 50, isolation: isolated (any Actor)? = #isolation, _ condition: () async -> T?) async -> T? {
    let deadline = Mono.now() + Double(timeoutMs) / 1000
    while true {
        if let v = await condition() { return v }
        if Mono.now() >= deadline { return nil }
        try? await Task.sleep(for: .milliseconds(everyMs))
    }
}
