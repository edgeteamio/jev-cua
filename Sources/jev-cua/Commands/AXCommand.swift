import ApplicationServices
import Foundation
import JevCore
import JevMac

/// `jev-cua ax [--app <name>] [--walk] [--json] [--depth N] [--max N] [--whole-app]`
/// Raw tree of the frontmost (or named running) app's focused window; `--walk` runs the
/// perception walk instead and `--json` writes a target-fixture skeleton for `lab --targets`.
enum AXCommand {
    static func run(_ args: Args) async throws {
        guard Permissions.accessibility(prompt: false) == .authorized else { throw UsageError("accessibility permission not granted for this process") }
        if args.flag("urls") {
            let front = Apps.frontmost()
            print("address bar: \(Browser.currentURL(pid: front.pid) ?? "nil")")
            print("document:    \(Browser.documentURL(pid: front.pid) ?? "nil")")
            return
        }
        if args.flag("focused") {
            // The focused element's text attributes: what a type action can read, select, and set.
            let front = Apps.frontmost()
            print("app: \(front.name)")
            for line in AXDump.focusedText(pid: front.pid) { print(line) }
            if let n = args.int("caret", default: -1) as Int?, n >= 0, let el = AX.focusedElement(pid: front.pid) {
                print("caret at \(n): \(AX.selectText(el, range: CFRange(location: n, length: 0)) ? "accepted" : "refused")")
            }
            if let which = args.string("select-keys") {
                // Probe the key fallback: the first line (Cmd+Up, Shift+Cmd+Right) or everything (Cmd+A).
                if which == "all" { Keys.press(Keys.aKey, flags: .maskCommand, pid: front.pid) }
                else { Keys.press(Keys.upArrowKey, flags: .maskCommand, pid: front.pid); Keys.press(Keys.rightArrowKey, flags: [.maskCommand, .maskShift], pid: front.pid) }
                try? await Task.sleep(for: .milliseconds(150))
                for line in AXDump.focusedText(pid: front.pid) where line.hasPrefix("selected range") { print("after keys (\(which)): \(line)") }
            }
            if let n = args.int("select", default: -1) as Int?, n >= 0, let el = AX.focusedElement(pid: front.pid) {
                // Probe: select the first n characters and read the range back.
                print("select 0..<\(n): \(AX.selectText(el, range: CFRange(location: 0, length: n)) ? "accepted" : "refused")")
                try? await Task.sleep(for: .milliseconds(100))
                for line in AXDump.focusedText(pid: front.pid) where line.hasPrefix("selected range") { print("after: \(line)") }
            }
            return
        }
        if let path = args.string("menu-item") {
            // A menu item as the executor sees it: found, enabled, and its shortcut.
            let front = Apps.frontmost()
            guard let item = MenuBar.item(pid: front.pid, path: path.components(separatedBy: " › ")) else { print("menu item '\(path)': not found"); return }
            let sc = AX.menuShortcut(item).map { "\($0.label) (key \($0.keyCode))" } ?? "none"
            print("menu item '\(path)': enabled=\(AX.bool(item, kAXEnabledAttribute) ?? true) shortcut=\(sc)")
            return
        }
        if args.flag("tabs") {
            // The browser tab strip as the menu evidence sees it: found or not, and how many tabs.
            let front = Apps.frontmost()
            let t0 = Date()
            if let strip = AX.tabStrip(pid: front.pid) {
                // Local diagnostic only: the selected tab's title is printed here, never sent anywhere.
                let sel = AX.children(strip).first { (AX.attr($0, kAXValueAttribute) as? NSNumber)?.intValue == 1 }.flatMap { AX.string($0, kAXTitleAttribute) } ?? "?"
                let win = AX.focusedWindow(AX.app(front.pid))
                let wins = (AX.attr(AX.app(front.pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
                let title = win.flatMap { AX.string($0, kAXTitleAttribute) } ?? "?"
                print("tab strip: found in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; tabs \(AX.tabCount(strip: strip)); selected '\(sel.prefix(40))'; windows \(wins.count); focused window '\(title.prefix(50))'")
                for (i, w) in wins.enumerated() {
                    let st = AX.find(in: w, maxNodes: 1200, maxDepth: 10, skipInto: ["AXWebArea"], where: { _, role in role == kAXTabGroupRole })
                    let newTabs = st.map { AX.children($0).filter { (AX.string($0, kAXTitleAttribute) ?? "").hasPrefix("New Tab") }.count } ?? -1
                    print("  window \(i) '\((AX.string(w, kAXTitleAttribute) ?? "?").prefix(40))': tabs \(st.map { AX.tabCount(strip: $0) } ?? -1), titled New Tab: \(newTabs), focused=\(win.map { CFEqual($0, w) } ?? false)")
                }
            }
            else { print("tab strip: not found (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)") }
            return
        }
        if args.flag("page-text") {
            let front = Apps.frontmost()
            for t in Browser.pageTexts(pid: front.pid) { print(t) }
            return
        }
        if args.flag("walk") {
            let r = try AXDump.walk(appName: args.string("app"))
            if args.flag("json") {
                let fixture = TargetFixture(app: r.appName, bundleId: r.bundleId, elements: r.elements, offscreen: r.offscreen, commands: [])
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try enc.encode(fixture), encoding: .utf8)!)
            } else {
                print("# \(r.appName) pid \(r.pid): \(r.elements.count) elements, \(r.offscreen.count) off-screen, \(r.nodes) nodes, \(r.collapsed) collapsed, truncated=\(r.truncated), \(Int(r.tookMs)) ms, \(r.axCalls) AX calls")
                for e in r.elements {
                    print(String(format: "%@  %@ '%@' (%@)%@ @%.0f,%.0f %.0fx%.0f", e.id, e.role, e.text, e.where, e.editable ? " editable" : "", e.frame.x, e.frame.y, e.frame.width, e.frame.height))
                }
                for e in r.offscreen { print("\(e.id)  \(e.role) '\(e.text)' (off-screen)") }
            }
            return
        }
        let r = try AXDump.dump(appName: args.string("app"), maxNodes: args.int("max", default: 800), maxDepth: args.int("depth", default: 14),
                                wholeApp: args.flag("whole-app"), menus: args.flag("menus"))
        print("# \(r.appName) pid \(r.pid): \(r.lines.count) nodes, \(r.axCalls) AX calls, \(Int(r.tookMs)) ms")
        print(AXDump.render(r.lines))
    }
}
