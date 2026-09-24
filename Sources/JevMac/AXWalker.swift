import AppKit
import ApplicationServices
import Foundation
import JevCore

/// The accessibility walk (plan section 5). One IPC per node through
/// `AXUIElementCopyMultipleAttributeValues`; bounded by `Config.walkNodeCap` and
/// `Config.walkTimeCapSeconds`; returns visible actionable elements in reading order, labelled
/// off-screen pressables, and the live references the executor needs to act on them.
public enum AXWalker {
    public struct Result: @unchecked Sendable {
        public var elements: [Element] = []
        public var offscreen: [Element] = []
        public var refs: [String: AXUIElement] = [:]
        public var truncated = false
        public var nodes = 0
        public var collapsed = 0
        public var tookMs: Double = 0
        public var windowFrame: Frame?
    }

    // No AXValue here: a note body's value is the whole document, and only static text needs it
    // (read separately during label adoption). Visible children are asked for big lists only.
    static let attributes: [String] = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                       kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXPlaceholderValueAttribute]
    static let listRoles: Set<String> = [kAXTableRole, kAXOutlineRole, kAXListRole, kAXBrowserRole]
    static let pressActions: Set<String> = [kAXPressAction, kAXConfirmAction, kAXShowMenuAction, kAXIncrementAction, kAXDecrementAction]
    static let containerRoles: Set<String> = [kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXToolbarRole, kAXWindowRole, kAXSheetRole,
                                              kAXDrawerRole, kAXLayoutAreaRole, kAXLayoutItemRole, "AXWebArea", kAXTabGroupRole, kAXListRole,
                                              kAXTableRole, kAXOutlineRole, kAXBrowserRole, kAXColumnRole, kAXScrollBarRole, kAXSplitterRole,
                                              kAXGrowAreaRole, kAXUnknownRole, kAXApplicationRole, "AXSection", "AXHeading"]
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    static let alwaysPressable: Set<String> = [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole,
                                               kAXMenuItemRole, kAXDisclosureTriangleRole, kAXIncrementorRole, kAXSliderRole, "AXTab", kAXMenuBarItemRole]

    private struct Node {
        var el: AXUIElement
        var role: String
        var subrole: String?
        var title: String?
        var description: String?
        var value: String?
        var placeholder: String?
        var enabled: Bool
        var frame: Frame?
        var children: [AXUIElement]
        var depth: Int
    }

    public static func walk(pid: pid_t, screen: Frame? = nil) -> Result {
        let t0 = Mono.now()
        var result = Result()
        let app = AX.app(pid)
        guard let root = AX.focusedWindow(app) else { result.tookMs = (Mono.now() - t0) * 1000; return result }
        let display = screen ?? Self.displayFrame()
        let isBrowserWindow = Browser.isBrowser(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        let windowFrame = AX.frame(root)
        result.windowFrame = windowFrame
        let visible = windowFrame.map { intersect($0, display) } ?? display
        var isRowVisible: (Frame) -> Bool = { f in overlaps(f, visible) }
        if visible.width < 1 || visible.height < 1 { isRowVisible = { _ in true } }

        struct Found { var element: Element; var ref: AXUIElement; var key: String; var priority: Int }
        var found: [Found] = []
        var offscreen: [Found] = []
        // Breadth first: toolbars and top-level controls are shallow, so they make the cut even
        // when a deep web area or note body exhausts the node or time budget.
        var queue: [(AXUIElement, Int, String, String?, Bool)] = [(root, 0, "", nil, false)]   // element, depth, parent role, named container, inside web content
        var head = 0
        let deadline = t0 + Config.walkTimeCapSeconds

        while head < queue.count {
            let (el, depth, parentRole, container, inWeb) = queue[head]; head += 1
            if result.nodes >= Config.walkNodeCap || Mono.now() > deadline { result.truncated = true; break }
            result.nodes += 1
            guard let node = read(el, depth: depth) else { continue }
            if node.role == kAXMenuBarRole || node.role == kAXMenuRole { continue }
            // A browser's tab strip: every tab is a page title, which is never sent (plan section 5).
            if parentRole == kAXTabGroupRole, node.role == kAXRadioButtonRole { continue }
            let onScreen = node.frame.map(isRowVisible) ?? true
            let tooSmall = node.frame.map { $0.width < 4 || $0.height < 4 } ?? false
            let editable = textRoles.contains(node.role) || node.subrole == "AXSearchField" || node.subrole == "AXSecureTextField"
            // A row is the selectable unit; its cells are not offered again.
            let selectableRow = (node.role == kAXRowRole || (node.role == kAXCellRole && parentRole != kAXRowRole)) && node.enabled
            // Roles that are pressable by definition skip the action query (one IPC per node);
            // static text, images, and containers never get it; other roles ask.
            let pressable: Bool
            if !node.enabled || containerRoles.contains(node.role) || node.role == kAXStaticTextRole || node.role == kAXImageRole || editable || selectableRow {
                pressable = false
            } else if alwaysPressable.contains(node.role) {
                pressable = true
            } else {
                pressable = !Set(AX.actions(el)).isDisjoint(with: pressActions)
            }
            let candidate = node.enabled && (pressable || editable || selectableRow)
            if candidate, let frame = node.frame, !tooSmall {
                let text = label(for: node, el: el)
                if !Config.isDenied(text: text) {
                    let role = AX.normalizeRole(node.role, subrole: node.subrole)
                    let where_ = gridWord(frame, in: windowFrame ?? display)
                    let e = Element(id: "", role: role, text: String(text.prefix(Config.maxElementTextChars)), where: where_, editable: editable,
                                    secure: node.subrole == "AXSecureTextField", frame: frame, container: container)
                    // Page content outranks browser chrome when the element cap bites.
                    let f = Found(element: e, ref: el, key: "\(role)|\(e.text)|\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))",
                                  priority: inWeb || !isBrowserWindow ? 0 : 1)
                    if onScreen { found.append(f) }
                    else if pressable, !text.isEmpty { offscreen.append(f) }
                }
            }
            // Children: a container is never a candidate, but what is inside it is. Off-screen
            // subtrees are not walked (their pressables surface through the off-screen list only
            // when the node itself was read). A text area's content is never walked.
            if depth < 40, onScreen || node.frame == nil, !editable {
                // A named list, table, outline, or group names its descendants' container.
                var named = container
                if listRoles.contains(node.role) || node.role == kAXGroupRole || node.role == kAXScrollAreaRole,
                   let name = (node.description ?? node.title)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 30 {
                    named = name
                }
                for c in node.children { queue.append((c, depth + 1, node.role, named, inWeb || node.role == "AXWebArea")) }
            }
        }

        // Reading order: rows by y (24 pt bands), then x; in a browser, page content first.
        found.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            let ra = Int(a.element.frame.y / 24), rb = Int(b.element.frame.y / 24)
            return ra != rb ? ra < rb : a.element.frame.x < b.element.frame.x
        }
        // Dedupe by (role, text, frame), then collapse identical descriptions (role, text, where).
        var seenKeys = Set<String>()
        var seenDesc = Set<String>()
        var kept: [Found] = []
        for f in found {
            guard seenKeys.insert(f.key).inserted else { continue }
            let desc = "\(f.element.role)|\(f.element.text)|\(f.element.where)"
            guard seenDesc.insert(desc).inserted else { result.collapsed += 1; continue }
            kept.append(f)
            if kept.count >= Config.maxElements { result.truncated = result.truncated || kept.count < found.count; break }
        }
        for (i, f) in kept.enumerated() {
            var e = f.element
            e.id = String(format: "e%02d", i + 1)
            result.elements.append(e)
            result.refs[e.id] = f.ref
        }
        // Off-screen pressables: labelled, deduped by role+label, minus labels already visible.
        let visibleLabels = Set(result.elements.map { "\($0.role)|\($0.text.lowercased())" })
        var seenOff = Set<String>()
        for f in offscreen {
            let k = "\(f.element.role)|\(f.element.text.lowercased())"
            guard !visibleLabels.contains(k), seenOff.insert(k).inserted else { continue }
            var e = f.element
            e.id = String(format: "o%03d", result.offscreen.count + 1)
            result.offscreen.append(e)
            result.refs[e.id] = f.ref
            if result.offscreen.count >= Config.maxOffscreenElements { break }
        }
        result.tookMs = (Mono.now() - t0) * 1000
        return result
    }

    // MARK: Reading

    private static func read(_ el: AXUIElement, depth: Int) -> Node? {
        AX.callCount += 1
        var values: CFArray?
        let names = attributes as CFArray
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let arr = values as? [AnyObject], arr.count == attributes.count else { return nil }
        func str(_ i: Int) -> String? {
            let v = arr[i]
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            if let a = v as? NSAttributedString { return a.string }
            return nil
        }
        func els(_ i: Int) -> [AXUIElement] { (arr[i] as? [AXUIElement]) ?? [] }
        let role = str(0) ?? ""
        var frame: Frame?
        if CFGetTypeID(arr[5]) == AXValueGetTypeID(), CFGetTypeID(arr[6]) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(arr[5] as! AXValue, .cgPoint, &p), AXValueGetValue(arr[6] as! AXValue, .cgSize, &s) {
                frame = Frame(x: p.x, y: p.y, width: s.width, height: s.height)
            }
        }
        var children = els(7)
        if listRoles.contains(role), children.count > 24, let visible = AX.attr(el, kAXVisibleChildrenAttribute) as? [AXUIElement], !visible.isEmpty {
            children = visible
        }
        var value: String? = nil
        if role == kAXStaticTextRole, let v = AX.string(el, kAXValueAttribute) { value = String(v.prefix(120)) }
        return Node(el: el, role: role, subrole: str(1), title: str(2), description: str(3), value: value, placeholder: str(8),
                    enabled: (arr[4] as? NSNumber)?.boolValue ?? true, frame: frame, children: children, depth: depth)
    }

    /// Title, else description, else placeholder (fields), else adopted static text from shallow
    /// children, capped (plan section 5).
    private static func label(for node: Node, el: AXUIElement) -> String {
        // Window controls carry no title; their subrole is the label.
        switch node.subrole {
        case "AXCloseButton": return "close window"
        case "AXMinimizeButton": return "minimize window"
        case "AXFullScreenButton": return "full screen"
        case "AXZoomButton": return "zoom window"
        default: break
        }
        if let t = node.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return clean(t) }
        if let d = node.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return clean(d) }
        if textRoles.contains(node.role), let p = node.placeholder?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return clean(p) }
        if node.role == kAXStaticTextRole || node.role == kAXMenuItemRole || node.role == "AXLink" || node.role == kAXButtonRole || node.role == kAXCheckBoxRole,
           let v = node.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !textRoles.contains(node.role) { return clean(v) }
        // Adopt shallow static text children (two levels), in order. Never for text fields: their
        // content is the user's, and a note body would cost dozens of calls.
        if textRoles.contains(node.role) { return "" }
        var parts: [String] = []
        var queue: [(AXUIElement, Int)] = node.children.prefix(8).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 12, parts.joined(separator: " ").count < Config.maxAdoptedLabelChars {
            let (c, d) = queue.removeFirst()
            visited += 1
            // One multi-attribute read per child: a labelled child (a cell with a description, a
            // static text with a value) contributes and is not descended into.
            guard let child = read(c, depth: d) else { continue }
            let own = [child.title, child.description, child.role == kAXStaticTextRole ? child.value : nil]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let own { parts.append(own) }
            else if d < 3, child.role != kAXTextAreaRole { for g in child.children.prefix(6) { queue.append((g, d + 1)) } }
        }
        return clean(String(parts.joined(separator: " ").prefix(Config.maxAdoptedLabelChars)))
    }

    static let emailPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    /// Whitespace folded; email addresses never leave the machine (plan section 5).
    private static func clean(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        return emailPattern.stringByReplacingMatches(in: folded, range: NSRange(folded.startIndex..., in: folded), withTemplate: "email")
    }

    // MARK: Geometry

    static func displayFrame() -> Frame {
        // AX coordinates: origin at the top-left of the primary display, y down.
        let all = NSScreen.screens
        guard let primary = all.first else { return Frame(x: 0, y: 0, width: 4000, height: 3000) }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for s in all {
            let f = s.frame
            let top = primary.frame.height - f.maxY
            minX = min(minX, f.minX); maxX = max(maxX, f.maxX)
            minY = min(minY, top); maxY = max(maxY, top + f.height)
        }
        return Frame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func intersect(_ a: Frame, _ b: Frame) -> Frame {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        return Frame(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    static func overlaps(_ a: Frame, _ b: Frame) -> Bool {
        a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
    }

    /// 3x3 grid word for a frame's centre inside `container`.
    public static func gridWord(_ f: Frame, in container: Frame) -> String {
        let (cx, cy) = f.center
        let col = container.width > 0 ? min(2, max(0, Int((cx - container.x) / container.width * 3))) : 1
        let row = container.height > 0 ? min(2, max(0, Int((cy - container.y) / container.height * 3))) : 1
        let rows = ["top", "middle", "bottom"], cols = ["left", "center", "right"]
        if row == 1 && col == 1 { return "center" }
        return "\(rows[row])-\(cols[col])"
    }
}
