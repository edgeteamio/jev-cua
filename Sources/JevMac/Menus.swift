import AppKit
import ApplicationServices
import Foundation
import JevCore

/// The front app's menu bar as candidates for a spoken menu command ("save", "close the window",
/// "new tab", "undo"), read through Accessibility with no per-app code (savka777/jev-use offers
/// the same surface). The Apple, Window, and Help menus and the "Open Recent", "Services", and
/// "Share" submenus are skipped: they carry window titles, file names, and other user content the
/// state must not include; so is any item whose title quotes a name ("Close “Untitled”").
public enum MenuBar {
    public struct Entry: Sendable, Equatable {
        public var path: [String]
        public var enabled: Bool
        public var title: String { path.joined(separator: " › ") }
    }

    static let skippedMenus: Set<String> = ["apple", "window", "help"]
    static let skippedSubmenus: Set<String> = ["open recent", "recent", "recent items", "services", "share", "dictionaries", "substitutions", "speech", "transformations"]

    /// Read once per app while it stays in front; menus rarely change shape. The enabled state is
    /// re-read at execution time.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [pid_t: (at: TimeInterval, entries: [Entry])] = [:]
    static let cacheTtlS: TimeInterval = 20

    public static func entries(pid: pid_t, maxItems: Int = 300) -> [Entry] {
        lock.lock()
        if let c = cache[pid], Mono.now() - c.at < cacheTtlS { lock.unlock(); return c.entries }
        lock.unlock()
        let read = readEntries(pid: pid, maxItems: maxItems)
        lock.lock(); cache[pid] = (Mono.now(), read); lock.unlock()
        return read
    }

    static func clean(_ title: String?) -> String {
        (title ?? "").replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func readEntries(pid: pid_t, maxItems: Int) -> [Entry] {
        guard let bar = AX.element(AX.app(pid), kAXMenuBarAttribute) else { return [] }
        var out: [Entry] = []
        for top in AX.children(bar).dropFirst() {   // the Apple menu is first
            let name = clean(AX.string(top, kAXTitleAttribute))
            guard !name.isEmpty, !skippedMenus.contains(name.lowercased()) else { continue }
            for menu in AX.children(top) { collect(menu, path: [name], depth: 1, into: &out, max: maxItems) }
            if out.count >= maxItems { break }
        }
        return out
    }

    private static func collect(_ menu: AXUIElement, path: [String], depth: Int, into out: inout [Entry], max: Int) {
        for item in AX.children(menu) {
            guard out.count < max, AX.string(item, kAXRoleAttribute) == kAXMenuItemRole else { continue }
            let title = clean(AX.string(item, kAXTitleAttribute))
            guard !title.isEmpty, !title.contains("“"), !title.contains("\"") else { continue }   // separators, quoted names
            let enabled = AX.bool(item, kAXEnabledAttribute) ?? true
            let submenus = AX.children(item).filter { AX.string($0, kAXRoleAttribute) == kAXMenuRole }
            if let sub = submenus.first {
                guard depth < 2, !skippedSubmenus.contains(title.lowercased()) else { continue }
                collect(sub, path: path + [title], depth: depth + 1, into: &out, max: max)
            } else {
                out.append(Entry(path: path + [title], enabled: enabled))
            }
        }
    }

    /// The live item for a path, for pressing; nil when the menu changed since it was read.
    public static func item(pid: pid_t, path: [String]) -> AXUIElement? {
        guard path.count >= 2, let bar = AX.element(AX.app(pid), kAXMenuBarAttribute) else { return nil }
        func norm(_ s: String) -> String { clean(s).lowercased() }
        guard let top = AX.children(bar).first(where: { norm(AX.string($0, kAXTitleAttribute) ?? "") == norm(path[0]) }) else { return nil }
        var menus = AX.children(top)
        for (i, name) in path.dropFirst().enumerated() {
            var found: AXUIElement? = nil
            for m in menus {
                if let hit = AX.children(m).first(where: { norm(AX.string($0, kAXTitleAttribute) ?? "") == norm(name) }) { found = hit; break }
            }
            guard let found else { return nil }
            if i == path.count - 2 { return found }
            menus = AX.children(found)
        }
        return nil
    }
}
