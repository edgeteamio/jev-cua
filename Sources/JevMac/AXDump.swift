import AppKit
import ApplicationServices
import Foundation
import JevCore

/// Debug dump of an application's accessibility tree (`jev-cua ax`). Bounded like the walker
/// that replaces it in Phase 4; prints one line per node with role, title, description, value.
public enum AXDump {
    public struct Line: Sendable {
        public var depth: Int
        public var role: String
        public var subrole: String?
        public var title: String?
        public var description: String?
        public var value: String?
        public var frame: String?
        public var enabled: Bool?
        public var actions: [String]
    }

    public struct Result: Sendable {
        public var appName: String
        public var pid: pid_t
        public var lines: [Line]
        public var axCalls: Int
        public var tookMs: Double
    }

    /// Dumps the named running app, or the frontmost one when `appName` is nil.
    public static func dump(appName: String?, maxNodes: Int = 800, maxDepth: Int = 14, wholeApp: Bool = false, menus: Bool = false) throws -> Result {
        let pid: pid_t, name: String
        if let wanted = appName {
            guard let a = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw AXDumpError.notRunning(wanted)
            }
            pid = a.processIdentifier; name = a.localizedName ?? wanted
        } else {
            let f = Apps.frontmost(); pid = f.pid; name = f.name
        }
        let t0 = Mono.now()
        AX.callCount = 0
        let lines = dump(pid: pid, maxNodes: maxNodes, maxDepth: maxDepth, wholeApp: wholeApp, menus: menus)
        return Result(appName: name, pid: pid, lines: lines, axCalls: AX.callCount, tookMs: (Mono.now() - t0) * 1000)
    }

    public struct WalkResult: Sendable {
        public var appName: String
        public var bundleId: String
        public var pid: pid_t
        public var elements: [Element]
        public var offscreen: [Element]
        public var nodes: Int
        public var collapsed: Int
        public var truncated: Bool
        public var tookMs: Double
        public var axCalls: Int
    }

    /// Runs the perception walk (AXWalker) on the named or frontmost app.
    /// The focused element's role, value, selected range, and which text attributes it lets a
    /// client set. Diagnoses replace-by-selection: Notes on 2026-09-20 kept the old title.
    public static func focusedText(pid: pid_t) -> [String] {
        guard let el = AX.focusedElement(pid: pid) else { return ["focused: none"] }
        var out: [String] = []
        out.append("role: \(AX.string(el, kAXRoleAttribute) ?? "?") subrole: \(AX.string(el, kAXSubroleAttribute) ?? "-")")
        let value = AX.string(el, kAXValueAttribute) ?? ""
        out.append("value (\(value.count) chars): \(String(value.prefix(120)).replacingOccurrences(of: "\n", with: "⏎"))")
        out.append("chars: \(AX.attr(el, kAXNumberOfCharactersAttribute).map { "\($0)" } ?? "-")")
        if let r = AX.attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { out.append("selected range: \(range.location)..<\(range.location + range.length)") }
        } else { out.append("selected range: -") }
        for name in [kAXSelectedTextRangeAttribute, kAXValueAttribute, kAXSelectedTextAttribute, kAXFocusedAttribute] {
            var settable: DarwinBoolean = false
            let err = AXUIElementIsAttributeSettable(el, name as CFString, &settable)
            out.append("settable \(name): \(err == .success ? (settable.boolValue ? "yes" : "no") : "err \(err.rawValue)")")
        }
        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] { out.append("attributes: \(list.joined(separator: " "))") }
        var params: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(el, &params) == .success, let list = params as? [String], !list.isEmpty { out.append("parameterized: \(list.joined(separator: " "))") }
        return out
    }

    public static func walk(appName: String?) throws -> WalkResult {
        let pid: pid_t, name: String, bundle: String
        if let wanted = appName {
            guard let a = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw AXDumpError.notRunning(wanted)
            }
            pid = a.processIdentifier; name = a.localizedName ?? wanted; bundle = a.bundleIdentifier ?? ""
        } else {
            let f = Apps.frontmost(); pid = f.pid; name = f.name; bundle = f.bundleId
        }
        AX.callCount = 0
        let r = AXWalker.walk(pid: pid)
        return WalkResult(appName: name, bundleId: bundle, pid: pid, elements: r.elements, offscreen: r.offscreen, nodes: r.nodes,
                          collapsed: r.collapsed, truncated: r.truncated, tookMs: r.tookMs, axCalls: AX.callCount)
    }

    public enum AXDumpError: Error, CustomStringConvertible {
        case notRunning(String)
        public var description: String { switch self { case .notRunning(let n): return "\(n) is not running" } }
    }

    static func dump(pid: pid_t, maxNodes: Int = 800, maxDepth: Int = 14, wholeApp: Bool = false, menus: Bool = false) -> [Line] {
        let app = AX.app(pid)
        let root: AXUIElement = menus ? (AX.element(app, kAXMenuBarAttribute) ?? app) : (wholeApp ? app : (AX.focusedWindow(app) ?? app))
        var out: [Line] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (el, depth) = stack.popLast(), out.count < maxNodes {
            let role = AX.string(el, kAXRoleAttribute) ?? "?"
            var value = AX.string(el, kAXValueAttribute)
            if let v = value, v.count > 60 { value = String(v.prefix(60)) + "…" }
            let frame = AX.frame(el).map { String(format: "%.0f,%.0f %.0fx%.0f", $0.x, $0.y, $0.width, $0.height) }
            out.append(Line(depth: depth, role: role, subrole: AX.string(el, kAXSubroleAttribute), title: AX.string(el, kAXTitleAttribute),
                            description: AX.string(el, kAXDescriptionAttribute), value: value, frame: frame,
                            enabled: AX.bool(el, kAXEnabledAttribute), actions: AX.actions(el)))
            if depth < maxDepth, role != kAXMenuBarRole || menus {
                for c in AX.children(el).reversed() { stack.append((c, depth + 1)) }
            }
        }
        return out
    }

    public static func render(_ lines: [Line]) -> String {
        lines.map { l in
            var parts: [String] = [l.role]
            if let s = l.subrole { parts.append("(\(s))") }
            if let t = l.title, !t.isEmpty { parts.append("title=\"\(t)\"") }
            if let d = l.description, !d.isEmpty { parts.append("desc=\"\(d)\"") }
            if let v = l.value, !v.isEmpty { parts.append("value=\"\(v.replacingOccurrences(of: "\n", with: "⏎"))\"") }
            if let f = l.frame { parts.append("@\(f)") }
            if l.enabled == false { parts.append("disabled") }
            if !l.actions.isEmpty { parts.append("[\(l.actions.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ","))]") }
            return String(repeating: "  ", count: l.depth) + parts.joined(separator: " ")
        }.joined(separator: "\n")
    }
}
