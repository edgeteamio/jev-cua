import AppKit
import Foundation
import JevCore

/// One handler per action with its fallback and its cheapest trustworthy verification (plan
/// section 11). Serialized by being an actor. Fallbacks run only after a verified failure,
/// never on a missing acknowledgement.
public actor MacExecutor: Executing {
    public enum Mode: Sendable { case live, dryRun }
    public var mode: Mode
    private let log: RunLog?
    private let resolver: (any ElementResolving)?

    public init(mode: Mode = .live, log: RunLog? = nil, resolver: (any ElementResolving)? = nil) {
        self.mode = mode; self.log = log; self.resolver = resolver
    }

    public func execute(_ candidate: Candidate, observation: Observation) async -> ExecutionOutcome {
        let t0 = Mono.now()
        if mode == .dryRun {
            return outcome(candidate, t0, .acknowledged, "dry run: not executed", .unknown, .none, "dry run", "")
        }
        guard candidate.repeats > 1, candidate.action.repeatable else { return await performOnce(candidate, t0, observation: observation) }
        // A spoken count: the action runs that many times, each verified on its own, and stops at
        // the first failure. The report says how many of the asked-for runs happened.
        var last: ExecutionOutcome? = nil
        var performed = 0
        for i in 0..<candidate.repeats {
            if i > 0 { try? await Task.sleep(for: .milliseconds(Config.repeatGapMs)) }
            let o = await performOnce(candidate, Mono.now(), observation: observation)
            last = o
            if o.result.status == .failed || o.verification.outcome == .failed { break }
            performed += 1
        }
        guard var o = last else { return outcome(candidate, t0, .failed, "nothing performed", .failed, .none, "", "") }
        o.result.detail = "\(o.result.detail); performed \(performed) of \(candidate.repeats)"
        o.result.tookMs = (Mono.now() - t0) * 1000
        if performed < candidate.repeats, o.verification.outcome == .verified {
            o.verification.outcome = .unknown
            o.verification.nextStep = "observe again"
        }
        return o
    }

    private func performOnce(_ candidate: Candidate, _ t0: TimeInterval, observation: Observation) async -> ExecutionOutcome {
        // Precondition recheck: the app the candidate was built against must still be frontmost
        // for actions that target its focused field.
        if case .typeText = candidate.action, candidate.targetElementId == nil {
            let now = Apps.frontmost()
            if now.bundleId != observation.app.bundleId {
                return outcome(candidate, t0, .failed, "frontmost app changed before typing", .failed, .frontmostApp, "app \(now.name)", "re-observe")
            }
            guard let field = now.pid > 0 ? AX.focusedField(pid: now.pid) : nil, !field.secure, field.role == observation.focusedField?.role else {
                return outcome(candidate, t0, .failed, "focused field changed before typing", .failed, .fieldValue, "no matching field", "re-observe")
            }
        }
        // Keys and scrolls go to whatever is in front, so the same recheck: a Return decided for
        // Notes reached another app when focus moved mid-run (sessions run 2026-09-28T12-42-41Z).
        switch candidate.action {
        case .pressEnter, .pressEscape, .scroll:
            let now = Apps.frontmost()
            if now.bundleId != observation.app.bundleId {
                return outcome(candidate, t0, .failed, "frontmost app changed before the key", .failed, .frontmostApp, "app \(now.name)", "re-observe")
            }
        default: break
        }
        switch candidate.action {
        case .openApp(let bundleId, let name): return await openApp(candidate, t0, bundleId: bundleId, name: name)
        case .newNote: return await newNote(candidate, t0)
        case .typeText(let text, let placement):
            if let target = candidate.targetElementId { return await typeInto(candidate, t0, text: text, placement: placement, elementId: target, observation: observation) }
            return await typeText(candidate, t0, text: text, placement: placement, observation: observation)
        case .webSearch(let url, let query, _): return await openURL(candidate, t0, url: url, expectHost: nil, expectQuery: query)
        case .openSite(let url, _): return await openURL(candidate, t0, url: url, expectHost: URL(string: url)?.host, expectQuery: nil)
        case .takePhoto: return await takePhoto(candidate, t0)
        case .pressEnter: return await key(candidate, t0, Keys.returnKey, name: "Return")
        case .pressEscape: return await key(candidate, t0, Keys.escapeKey, name: "Escape")
        case .scroll(let dir, let amount): return await scroll(candidate, t0, direction: dir, amount: amount)
        case .goBack: return await goBack(candidate, t0)
        case .clickElement(let id): return await clickElement(candidate, t0, elementId: id, observation: observation)
        case .menuItem(_, let path): return await menuItem(candidate, t0, path: path, observation: observation)
        }
    }

    /// Presses a menu-bar command found again by its path at press time (menus can change since
    /// the observation). Evidence that it ran: the focused window, focused element, window count,
    /// or the focused value changed, or the item's own enabled state flipped (Save after saving,
    /// Undo after undoing).
    private func menuItem(_ c: Candidate, _ t0: TimeInterval, path: String, observation: Observation) async -> ExecutionOutcome {
        let app = Apps.frontmost()
        guard app.bundleId == observation.app.bundleId else {
            return outcome(c, t0, .failed, "frontmost app changed before the menu command", .failed, .frontmostApp, "app \(app.name)", "re-observe")
        }
        let parts = path.components(separatedBy: " › ")
        guard let item = MenuBar.item(pid: app.pid, path: parts) else {
            return outcome(c, t0, .failed, "menu item '\(path)' not found", .failed, .snapshotDiff, "", "re-observe")
        }
        guard AX.bool(item, kAXEnabledAttribute) ?? true else {
            return outcome(c, t0, .failed, "menu item '\(path)' is disabled", .failed, .snapshotDiff, "disabled", "")
        }
        let ax = AX.app(app.pid)
        let windowBefore = AX.focusedWindow(ax)
        let focusBefore = AX.element(ax, kAXFocusedUIElementAttribute)
        let countBefore = AX.windowCount(pid: app.pid)
        let valueBefore = AX.focusedValue(pid: app.pid)
        let selectionBefore = focusBefore.flatMap(AX.selectedRange)
        // The tab strip is found once (a bounded search) and its children polled after the press.
        let strip = Browser.isBrowser(app.bundleId) ? AX.tabStrip(pid: app.pid) : nil
        let tabsBefore = strip.map { AX.tabCount(strip: $0) }
        func change() -> String? {
            if AX.windowCount(pid: app.pid) != countBefore { return "window count \(countBefore) -> \(AX.windowCount(pid: app.pid))" }
            if let strip, let tb = tabsBefore, AX.tabCount(strip: strip) != tb { return "tab count \(tb) -> \(AX.tabCount(strip: strip))" }
            if let f = focusBefore, let s = AX.selectedRange(f), let sb = selectionBefore, s.location != sb.location || s.length != sb.length { return "selection \(sb.location)..<\(sb.location + sb.length) -> \(s.location)..<\(s.location + s.length)" }
            if let w = AX.focusedWindow(ax), let wb = windowBefore, !CFEqual(w, wb) { return "focused window changed" }
            if let f = AX.element(ax, kAXFocusedUIElementAttribute), let fb = focusBefore, !CFEqual(f, fb) { return "focus moved" }
            if AX.focusedValue(pid: app.pid) != valueBefore { return "focused value changed" }
            if Apps.frontmost().pid != app.pid { return "app changed" }
            if let again = MenuBar.item(pid: app.pid, path: parts), (AX.bool(again, kAXEnabledAttribute) ?? true) == false { return "'\(parts.last ?? path)' is now disabled" }
            return nil
        }
        // AXPress first (exact, no key state to get wrong); the item's own shortcut only when the
        // press is refused. An accepted press that shows nothing is an unknown outcome, and sending
        // the shortcut then repeats it: File › Close Tab twice closes two tabs, or the window with
        // the last one. Silence is no proof: in a window of many tabs the strip's count stayed at
        // 18 through a verified close (2026-09-29), and from a New Tab page nothing else moves.
        // The shortcut rescued none of the silent presses it followed in the run logs.
        var how = "pressed '\(path)'"
        if AX.press(item) {
            if let changed = await waitFor(timeoutMs: 1500, change) { return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, changed, "") }
        } else if let key = AX.menuShortcut(item) {
            // Through the HID tap, not posted to the pid: Chrome drops app-level accelerators
            // posted to its process (as it drops posted scroll wheels). The app is frontmost, checked above.
            Keys.press(key.keyCode, flags: key.flags, pid: nil)
            how = "'\(path)' via \(key.label)"
            if let changed = await waitFor(timeoutMs: 1500, change) { return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, changed, "") }
        } else {
            return outcome(c, t0, .failed, "press refused and no shortcut", .failed, .snapshotDiff, "", "re-observe")
        }
        // Nothing changed: in Chrome, first rule out the profile picker, which takes every new-tab
        // and close-tab while it is open, and say so instead of "no observable change".
        if Browser.isBrowser(app.bundleId), Browser.profilePickerOpen(pid: app.pid) {
            return outcome(c, t0, .failed, Browser.profilePickerDetail, .failed, .snapshotDiff, "profile picker window open", "close Chrome's profile picker")
        }
        return outcome(c, t0, .acknowledged, how, .unknown, .snapshotDiff, "no observable change", "observe again")
    }

    // MARK: Handlers

    /// Launches or activates and waits for the app to be frontmost. A cold launch gets
    /// `Config.coldLaunchWaitMs`; an already-running app `Config.activateWaitMs`.
    private func bringToFront(bundleId: String, name: String) async -> (app: AppIdentity?, wasRunning: Bool) {
        let wasRunning = !bundleId.isEmpty && Apps.running(bundleId: bundleId) != nil
        guard await Apps.activate(bundleId: bundleId, name: name) else { return (nil, wasRunning) }
        let front = await waitFor(timeoutMs: wasRunning ? Config.activateWaitMs : Config.coldLaunchWaitMs) { () -> AppIdentity? in
            let f = Apps.frontmost()
            return (!bundleId.isEmpty ? f.bundleId == bundleId : f.name.caseInsensitiveCompare(name) == .orderedSame) ? f : nil
        }
        return (front, wasRunning)
    }

    private func openApp(_ c: Candidate, _ t0: TimeInterval, bundleId: String, name: String) async -> ExecutionOutcome {
        let before = Apps.frontmost()
        if !bundleId.isEmpty, before.bundleId == bundleId {
            return outcome(c, t0, .acknowledged, "already frontmost", .verified, .frontmostApp, before.name, "")
        }
        let (front, wasRunning) = await bringToFront(bundleId: bundleId, name: name)
        if let front { return outcome(c, t0, .acknowledged, wasRunning ? "activated" : "launched", .verified, .frontmostApp, front.name, "") }
        if Apps.url(bundleId: bundleId, name: name) == nil {
            return outcome(c, t0, .failed, "could not find \(name)", .failed, .frontmostApp, before.name, "check the app exists")
        }
        return outcome(c, t0, .acknowledged, "activation requested", .unknown, .frontmostApp, Apps.frontmost().name, "observe again")
    }

    /// Rows in the note list of the focused Notes window: the biggest outline, table, or list
    /// that is not the Folders sidebar (which is described as such).
    private func listRowCount(pid: pid_t) -> Int? {
        guard let win = AX.focusedWindow(AX.app(pid)) else { return nil }
        var best: Int?
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == kAXOutlineRole || role == kAXTableRole || role == kAXListRole {
                let desc = (AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXTitleAttribute) ?? "").lowercased()
                if !desc.contains("folder") {
                    let rows = (AX.attr(el, kAXRowsAttribute) as? [AXUIElement])?.count ?? AX.children(el).filter { AX.string($0, kAXRoleAttribute) == kAXRowRole }.count
                    best = max(best ?? 0, rows)
                }
                continue   // rows are not walked
            }
            if depth < 8, role != kAXMenuBarRole { for c in AX.children(el) { queue.append((c, depth + 1)) } }
        }
        return best
    }

    private func newNote(_ c: Candidate, _ t0: TimeInterval) async -> ExecutionOutcome {
        guard let notes = await bringToFront(bundleId: "com.apple.Notes", name: "Notes").app else {
            return outcome(c, t0, .failed, "Notes did not come to the front", .failed, .frontmostApp, Apps.frontmost().name, "")
        }
        // Notes opens its window a beat after it becomes frontmost on a cold launch.
        _ = await waitFor(timeoutMs: 2000) { AX.focusedWindow(AX.app(notes.pid)) }
        let rowsBefore = listRowCount(pid: notes.pid)
        let fieldBefore = AX.focusedField(pid: notes.pid)
        Keys.press(Keys.nKey, flags: .maskCommand, pid: notes.pid)
        // Strongest cheap evidence: one more row in the note list. Else: the focused element is
        // an empty text area that was not focused-and-empty before, which only a fresh note gives.
        let evidence = await waitFor(timeoutMs: 1200) { () -> (VerificationEvidence, String)? in
            if let b = rowsBefore, let a = self.listRowCount(pid: notes.pid), a > b { return (.noteCount, "note list \(b) -> \(a) rows") }
            if let f = AX.focusedField(pid: notes.pid), f.role == "textarea", (f.valuePreview ?? "").isEmpty,
               !(fieldBefore?.role == "textarea" && (fieldBefore?.valuePreview ?? "").isEmpty) {
                return (.fieldValue, "empty note body focused")
            }
            return nil
        }
        if let (ev, observed) = evidence { return outcome(c, t0, .acknowledged, "Cmd+N", .verified, ev, observed, "") }
        // Notes reuses an empty note instead of adding another: an empty note body focused before
        // and after Cmd+N is the postcondition already met.
        if fieldBefore?.role == "textarea", (fieldBefore?.valuePreview ?? "").isEmpty,
           let now = AX.focusedField(pid: notes.pid), now.role == "textarea", (now.valuePreview ?? "").isEmpty {
            return outcome(c, t0, .acknowledged, "Cmd+N", .verified, .fieldValue, "an empty note is already open (Notes reuses it)", "")
        }
        let observed = rowsBefore.map { "note list still \($0) rows" } ?? "note list not readable"
        return outcome(c, t0, .acknowledged, "Cmd+N sent", .unknown, .noteCount, observed, "observe again")
    }

    private func typeText(_ c: Candidate, _ t0: TimeInterval, text textIn: String, placement: TextPlacement, observation: Observation) async -> ExecutionOutcome {
        let app = Apps.frontmost()
        let before = AX.focusedValue(pid: app.pid) ?? ""
        // A leading newline means "start a new line first" (a note body after its title).
        var text = textIn
        if text.hasPrefix("\n") {
            Keys.press(Keys.returnKey, pid: app.pid)
            try? await Task.sleep(for: .milliseconds(60))
            text = String(text.dropFirst())
        }
        let el = AX.focusedElement(pid: app.pid)
        let how = await enter(text, into: el, pid: app.pid, placement: placement, before: before) { AX.focusedValue(pid: app.pid) ?? "" }
        let after = await waitFor(timeoutMs: 800) { () -> String? in
            let v = AX.focusedValue(pid: app.pid) ?? ""
            return self.typed(text, placement: placement, before: before, now: v) ? v : nil
        }
        if let after { return outcome(c, t0, .acknowledged, how, .verified, .fieldValue, String(after.suffix(80)), "") }
        return outcome(c, t0, .acknowledged, "text sent (\(how))", .unknown, .fieldValue, String((AX.focusedValue(pid: app.pid) ?? "").suffix(80)), "observe again")
    }

    /// Puts `text` into the focused element: selects what a replacement overwrites, then sets
    /// `AXSelectedText` when the element takes it (one call, no keystroke race, no autocorrect
    /// rewriting a glued word), else sends keystrokes. Borrowed from savka777/jev-use, which
    /// tries the attribute first. A set that is accepted but applied late would double the text
    /// if keystrokes followed at once, so the value is read back before falling back.
    private func enter(_ text: String, into el: AXUIElement?, pid: pid_t, placement: TextPlacement, before: String, value: @escaping () -> String) async -> String {
        var how = ""
        var keys = text
        if let el {
            if placement == .insert {
                if Self.needsLeadingSpace(el, value: before) { keys = " " + text; how = " after a space" }
            } else {
                how = ", " + (await selectForReplacement(el, pid: pid, placement: placement, value: before))
            }
            // Chrome accepts the set and never applies it; after one such miss the process gets
            // keystrokes directly instead of paying the read-back wait every time.
            if !axInsertMisses.contains(pid), AX.isSettable(el, kAXSelectedTextAttribute),
               AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, keys as CFString) == .success {
                if await waitFor(timeoutMs: 250, everyMs: 20, { self.typed(text, placement: placement, before: before, now: value()) ? true : nil }) == true {
                    return "set \(text.count) chars through AXSelectedText" + how
                }
                axInsertMisses.insert(pid)
            }
        }
        await Keys.type(keys, pid: pid)
        return "typed \(text.count) chars" + how
    }

    /// Processes where a successful `AXSelectedText` set changed nothing.
    private var axInsertMisses = Set<pid_t>()

    /// Selects the text a replacement overwrites: the whole value, or its first line (a note's
    /// title). AXSelectedTextRange is exact and moves nothing else; when the app refuses it,
    /// keys do the same job (Cmd+A; Cmd+Up then Shift+Cmd+Right to the end of the first line).
    private func selectForReplacement(_ el: AXUIElement, pid: pid_t, placement: TextPlacement, value: String) async -> String {
        let length = placement == .replaceAll ? value.utf16.count : Self.firstLine(value).utf16.count
        // Accepted is not applied: read the range back before the keystrokes go out.
        if AX.selectText(el, range: CFRange(location: 0, length: length)),
           await waitFor(timeoutMs: 400, everyMs: 20, { AX.selectedRange(el).flatMap { $0.location == 0 && $0.length == length ? true : nil } }) == true {
            return "selected 0..<\(length) to replace"
        }
        switch placement {
        case .replaceAll: Keys.press(Keys.aKey, flags: .maskCommand, pid: pid)
        case .replaceTitle:
            Keys.press(Keys.upArrowKey, flags: .maskCommand, pid: pid)
            Keys.press(Keys.rightArrowKey, flags: [.maskCommand, .maskShift], pid: pid)
        case .insert: break
        }
        try? await Task.sleep(for: .milliseconds(60))
        return "selected by keys to replace"
    }

    /// An insert whose caret sits right after a word gets a space first, so "type hello" after
    /// "eggs" reads "eggs hello", not "eggshello" (which Notes then autocorrects into something
    /// else). A caret at the start, after whitespace, or with a selection needs none.
    static func needsLeadingSpace(_ el: AXUIElement, value: String) -> Bool {
        guard let r = AX.selectedRange(el), r.length == 0, r.location > 0, r.location <= value.utf16.count else { return false }
        let u = value.utf16
        guard let scalar = Unicode.Scalar(u[u.index(u.startIndex, offsetBy: r.location - 1)]) else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func firstLine(_ value: String) -> Substring {
        value.firstIndex(where: \.isNewline).map { value[..<$0] } ?? value[...]
    }

    /// Postcondition of a type action. An insert needs the text present and the value changed; a
    /// replacement needs the old text gone: the first line, or the whole value, is now the text.
    /// (An append would pass the insert test, which is why replacements get their own.)
    func typed(_ text: String, placement: TextPlacement, before: String, now: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch placement {
        // Case-insensitive: Notes capitalizes the first letter of a new line, so a body typed as
        // "milk and eggs" reads back "Milk and eggs" and is still the text that was entered.
        case .insert: return now != before && now.localizedCaseInsensitiveContains(text)
        case .replaceTitle: return Self.firstLine(now).trimmingCharacters(in: .whitespaces) == t
        case .replaceAll: return now.trimmingCharacters(in: .whitespacesAndNewlines) == t
        }
    }

    private func chromeURL() -> String? {
        let front = Apps.frontmost()
        let pid = Browser.isBrowser(front.bundleId) ? front.pid : (Apps.running(bundleId: "com.google.Chrome")?.processIdentifier ?? 0)
        return pid > 0 ? Browser.currentURL(pid: pid) : nil
    }

    private func openURL(_ c: Candidate, _ t0: TimeInterval, url: String, expectHost: String?, expectQuery: String?) async -> ExecutionOutcome {
        guard let u = URL(string: url) else { return outcome(c, t0, .failed, "bad url", .failed, .url, url, "") }
        let chrome = Apps.url(bundleId: "com.google.Chrome", name: "Google Chrome")
        // A browser already in front with a page open navigates in that tab (Cmd+L, the URL,
        // Return), so back and forward keep working; otherwise the URL opens in a new tab.
        let front = Apps.frontmost()
        var how = "opened"
        if Browser.isBrowser(front.bundleId), let cur = Browser.currentURL(pid: front.pid), !cur.isEmpty, !cur.contains("newtab"), !cur.hasPrefix("chrome://") {
            Keys.press(Keys.lKey, flags: .maskCommand, pid: front.pid)
            try? await Task.sleep(for: .milliseconds(80))
            await Keys.type(url, pid: front.pid)
            Keys.press(Keys.returnKey, pid: front.pid)
            how = Undo.navigatedInPlace
        } else {
            guard await Apps.open(url: u, inAppAt: chrome) else { return outcome(c, t0, .failed, "open failed", .failed, .url, "", "") }
        }
        let host = (expectHost ?? u.host ?? "").replacingOccurrences(of: "www.", with: "")
        let query = expectQuery?.lowercased()
        // The committed document URL when the web area exposes one (the address bar echoes typed
        // text before a navigation commits), else the address bar.
        let typed = how != "opened"
        let seen = await waitFor(timeoutMs: 4000) { () -> String? in
            let pid = Apps.running(bundleId: "com.google.Chrome")?.processIdentifier ?? 0
            let doc = pid > 0 ? Browser.documentURL(pid: pid) : nil
            guard let cur = (typed ? (doc ?? nil) : (doc ?? self.chromeURL()))?.lowercased() else { return nil }
            let hostOk = cur.contains(host.lowercased())
            let queryOk = query.map { q in cur.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.contains(q) ?? false } ?? true
            return hostOk && queryOk ? cur : nil
        }
        if let seen {
            if let pid = Apps.running(bundleId: "com.google.Chrome")?.processIdentifier { await Browser.waitForLoad(pid: pid) }
            return outcome(c, t0, .acknowledged, how, .verified, .url, String(seen.prefix(120)), "")
        }
        if how != "opened" {
            // Typed navigation did not take: open it the plain way.
            _ = await Apps.open(url: u, inAppAt: chrome)
            if let seen2 = await waitFor(timeoutMs: 3000, { () -> String? in
                guard let cur = self.chromeURL()?.lowercased() else { return nil }
                return cur.contains(host.lowercased()) ? cur : nil
            }) { return outcome(c, t0, .acknowledged, "opened (typed navigation did not take)", .verified, .url, String(seen2.prefix(120)), "") }
        }
        let cur = chromeURL().map { String($0.prefix(120)) } ?? "address bar not readable"
        return outcome(c, t0, .acknowledged, "open requested", .unknown, .url, cur, "observe again")
    }

    private func photoCount() -> Int {
        let dir = NSHomeDirectory() + "/Pictures/Photo Booth Library/Pictures"
        return (try? FileManager.default.contentsOfDirectory(atPath: dir))?.count ?? -1
    }

    private func takePhoto(_ c: Candidate, _ t0: TimeInterval) async -> ExecutionOutcome {
        guard let pb = await bringToFront(bundleId: "com.apple.PhotoBooth", name: "Photo Booth").app else {
            return outcome(c, t0, .failed, "Photo Booth did not come to the front", .failed, .frontmostApp, Apps.frontmost().name, "")
        }
        let before = photoCount()
        // Let the camera warm up; File > Take Photo is disabled until it has (and during a capture).
        let item = await waitFor(timeoutMs: 2500) { () -> AXUIElement? in
            guard let m = AX.menuItem(pid: pb.pid, menu: "File", item: "Take Photo"), AX.bool(m, kAXEnabledAttribute) ?? false else { return nil }
            return m
        }
        let exportBefore = AX.menuItem(pid: pb.pid, menu: "File", item: "Export").flatMap { AX.bool($0, kAXEnabledAttribute) } ?? false
        var how: String
        if let item, AX.press(item) { how = "File > Take Photo" }
        else if let win = AX.focusedWindow(AX.app(pb.pid)),
                let button = AX.find(in: win, maxNodes: 300, where: { el, role in
                    role == "AXButton" && ["take photo", "take picture", "take a photo"].contains((AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXTitleAttribute) ?? "").lowercased()) }),
                AX.press(button) { how = "AX press Take Photo" }
        else { Keys.press(Keys.returnKey, pid: pb.pid); how = "Return key" }
        // Photo Booth counts down for about 3 s before the shutter. Evidence, strongest first: a
        // new file in the library (readable only with a Files grant; -1 means unreadable); File >
        // Take Photo going disabled for the countdown and capture and coming back (measured:
        // disabled within 250 ms of the press, for ~4.5 s); File > Export turning enabled (the
        // first photo ever).
        let disabled = await waitFor(timeoutMs: 1500) { () -> Bool? in
            guard let m = AX.menuItem(pid: pb.pid, menu: "File", item: "Take Photo") else { return nil }
            return (AX.bool(m, kAXEnabledAttribute) ?? true) ? nil : true
        }
        if before >= 0, let after = await waitFor(timeoutMs: 8000, { () -> Int? in let n = self.photoCount(); return n > before ? n : nil }) {
            return outcome(c, t0, .acknowledged, how, .verified, .fileCount, "\(before) -> \(after) pictures", "")
        }
        if disabled == true {
            return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, "photo taken: the shutter countdown ran", "")
        }
        if !exportBefore, let _ = await waitFor(timeoutMs: 6000, { () -> Bool? in
            guard let m = AX.menuItem(pid: pb.pid, menu: "File", item: "Export"), AX.bool(m, kAXEnabledAttribute) ?? false else { return nil }
            return true
        }) {
            return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, "File > Export became enabled: a photo exists", "")
        }
        return outcome(c, t0, .acknowledged, how, .unknown, .snapshotDiff, before >= 0 ? "\(before) pictures, no capture seen" : "library unreadable, no capture seen", "check Photo Booth")
    }

    // MARK: Elements (Phase 4)

    /// Semantic freshness guard (plan 9.3): the element must still be there with the same role
    /// and label (or frame), and the point at its centre must hit it or a descendant, else
    /// something is covering it and the click is refused with a re-observe.
    private func fresh(_ r: ElementRef) -> (ok: Bool, why: String, frame: Frame?) {
        let role = AX.normalizeRole(AX.string(r.ref, kAXRoleAttribute) ?? "", subrole: AX.string(r.ref, kAXSubroleAttribute))
        guard !role.isEmpty else { return (false, "element gone", nil) }
        guard role == r.element.role else { return (false, "role changed to \(role)", nil) }
        let frame = AX.frame(r.ref)
        let title = (AX.string(r.ref, kAXTitleAttribute) ?? AX.string(r.ref, kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sameLabel = r.element.text.isEmpty || title.isEmpty || title.hasPrefix(String(r.element.text.prefix(20)))
        let sameFrame = frame.map { abs($0.x - r.element.frame.x) < 2 && abs($0.y - r.element.frame.y) < 2 } ?? false
        guard sameLabel || sameFrame else { return (false, "label and frame changed", frame) }
        guard let f = frame, f.width >= 1, f.height >= 1 else { return (true, "no frame (off-screen press)", nil) }
        var hit: AXUIElement?
        let (cx, cy) = f.center
        if AXUIElementCopyElementAtPosition(AX.app(r.pid), Float(cx), Float(cy), &hit) == .success, let hit {
            if CFEqual(hit, r.ref) { return (true, "hit-test ok", f) }
            if let hf = AX.frame(hit), hf.x >= f.x - 1, hf.y >= f.y - 1, hf.x + hf.width <= f.x + f.width + 1, hf.y + hf.height <= f.y + f.height + 1 {
                return (true, "hit-test inside", f)
            }
            let hitRole = AX.string(hit, kAXRoleAttribute) ?? "?"
            if hitRole == kAXSheetRole || hitRole == kAXWindowRole { return (false, "covered by a \(hitRole)", f) }
            // Some apps hit-test to a container; accept when the hit element contains ours.
            if let hf = AX.frame(hit), hf.x <= f.x + 1, hf.y <= f.y + 1, hf.x + hf.width >= f.x + f.width - 1, hf.y + hf.height >= f.y + f.height - 1 {
                return (true, "hit-test container", f)
            }
            return (false, "covered by \(hitRole)", f)
        }
        return (true, "hit-test unavailable", f)
    }

    private func clickElement(_ c: Candidate, _ t0: TimeInterval, elementId: String, observation: Observation) async -> ExecutionOutcome {
        guard let resolver, let r = await resolver.resolve(elementId: elementId, snapshotId: observation.snapshotId) else {
            return outcome(c, t0, .failed, "element \(elementId) is not in the current snapshot", .failed, .snapshotDiff, "", "re-observe")
        }
        let front = Apps.frontmost()
        guard front.pid == r.pid else {
            return outcome(c, t0, .failed, "frontmost app changed before the click", .failed, .frontmostApp, front.name, "re-observe")
        }
        let f = fresh(r)
        guard f.ok else { return outcome(c, t0, .failed, "stale target: \(f.why)", .failed, .snapshotDiff, f.why, "re-observe") }
        if let sub = AX.string(r.ref, kAXSubroleAttribute), Self.windowButtons.contains(sub) {
            return await windowButton(c, t0, r, frame: f.frame)
        }
        let app = AX.app(r.pid)
        let focusBefore = AX.element(app, kAXFocusedUIElementAttribute)
        let windowBefore = AX.focusedWindow(app)
        let valueBefore = AX.string(r.ref, kAXValueAttribute)
        // Baselines for the page evidence, taken before the press.
        let isBrowser = Browser.isBrowser(front.bundleId)
        let urlBefore = isBrowser ? Browser.currentURL(pid: r.pid) : nil
        let pageTextBefore = isBrowser && r.element.role == "button" ? Browser.pageTextDigest(pid: r.pid) : nil
        let actions = Set(AX.actions(r.ref))
        var how = "AXPress"
        var pressed = AX.press(r.ref)
        if !pressed, actions.contains(kAXConfirmAction) { pressed = AXUIElementPerformAction(r.ref, kAXConfirmAction as CFString) == .success; how = "AXConfirm" }
        if !pressed, actions.contains(kAXShowMenuAction) { pressed = AXUIElementPerformAction(r.ref, kAXShowMenuAction as CFString) == .success; how = "AXShowMenu" }
        if !pressed, let frame = f.frame {
            // Fallback: a synthetic click at the centre, only after a verified AX refusal.
            let (cx, cy) = frame.center
            Keys.click(at: CGPoint(x: cx, y: cy))
            pressed = true; how = "click at centre"
        }
        guard pressed else { return outcome(c, t0, .failed, "press refused", .failed, .snapshotDiff, f.why, "re-observe") }
        // In a browser a link or button click is expected to change the page: a page button
        // usually changes the page's text in place, a link changes the URL. AXPress on web
        // content is sometimes ignored; a real click follows a verified no-op.
        if let before = pageTextBefore {
            if let _ = await waitFor(timeoutMs: 900, { () -> Bool? in Browser.pageTextDigest(pid: r.pid) != before ? true : nil }) {
                return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, "page text changed", "")
            }
        }
        if isBrowser, r.element.role == "link" || r.element.role == "button" {
            if let u = await waitFor(timeoutMs: r.element.role == "link" ? 1500 : 600, { () -> String? in let u = Browser.currentURL(pid: r.pid); return u != urlBefore ? u : nil }) {
                await Browser.waitForLoad(pid: r.pid)
                return outcome(c, t0, .acknowledged, how, .verified, .url, String((URL(string: u)?.host ?? u).prefix(80)), "")
            }
            if how == "AXPress", let frame = f.frame {
                let (cx, cy) = frame.center
                Keys.click(at: CGPoint(x: cx, y: cy))
                how = "AXPress (no effect), then click at centre"
                if let before = pageTextBefore, let _ = await waitFor(timeoutMs: 900, { () -> Bool? in Browser.pageTextDigest(pid: r.pid) != before ? true : nil }) {
                    return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, "page text changed", "")
                }
                if let u = await waitFor(timeoutMs: r.element.role == "link" ? 2000 : 600, { () -> String? in let u = Browser.currentURL(pid: r.pid); return u != urlBefore ? u : nil }) {
                    await Browser.waitForLoad(pid: r.pid)
                    return outcome(c, t0, .acknowledged, how, .verified, .url, String((URL(string: u)?.host ?? u).prefix(80)), "")
                }
            }
            // Neither the page text nor the URL moved: a focus change is not evidence on a page.
            return outcome(c, t0, .acknowledged, how, .unknown, .snapshotDiff, "page text and URL unchanged", "observe again")
        }
        let changed = await waitFor(timeoutMs: 800) { () -> String? in
            let focus = AX.element(app, kAXFocusedUIElementAttribute)
            if let a = focus, let b = focusBefore, !CFEqual(a, b) { return "focus moved" }
            if focus != nil && focusBefore == nil { return "focus set" }
            if let w = AX.focusedWindow(app), let wb = windowBefore, !CFEqual(w, wb) { return "window changed" }
            if AX.string(r.ref, kAXValueAttribute) != valueBefore { return "value changed" }
            if Apps.frontmost().pid != r.pid { return "app changed" }
            return nil
        }
        if let changed { return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, changed, "") }
        return outcome(c, t0, .acknowledged, how, .unknown, .snapshotDiff, "no observable change", "observe again")
    }

    private static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// A window's own close, minimize, zoom, or full-screen button. Not page content, even in a
    /// browser: its evidence is the window (the page-text check read the next window's page as
    /// "page text changed" when Chrome's close button shut a window, 2026-09-28), and there is no
    /// second click, which after a close lands on whatever lies underneath, another window's
    /// close button when windows stack.
    private func windowButton(_ c: Candidate, _ t0: TimeInterval, _ r: ElementRef, frame: Frame?) async -> ExecutionOutcome {
        let app = AX.app(r.pid)
        let window = AX.element(r.ref, kAXWindowAttribute)
        let countBefore = AX.windowCount(pid: r.pid)
        let focusedBefore = AX.focusedWindow(app)
        let frameBefore = window.flatMap(AX.frame)
        var how = "AXPress"
        if !AX.press(r.ref) {
            // A synthetic click only after a verified AX refusal, as for any control.
            guard let frame else { return outcome(c, t0, .failed, "press refused", .failed, .snapshotDiff, "", "re-observe") }
            let (cx, cy) = frame.center
            Keys.click(at: CGPoint(x: cx, y: cy))
            how = "click at centre"
        }
        let changed = await waitFor(timeoutMs: 1500) { () -> String? in
            let count = AX.windowCount(pid: r.pid)
            if count != countBefore { return "window count \(countBefore) -> \(count)" }
            if let w = window, AX.bool(w, kAXMinimizedAttribute) == true { return "window minimized" }
            if let w = window, let fb = frameBefore, let fa = AX.frame(w), fa != fb { return "window frame changed" }
            if let w = AX.focusedWindow(app), let wb = focusedBefore, !CFEqual(w, wb) { return "focused window changed" }
            if Apps.frontmost().pid != r.pid { return "app changed" }
            return nil
        }
        if let changed { return outcome(c, t0, .acknowledged, how, .verified, .snapshotDiff, changed, "") }
        return outcome(c, t0, .acknowledged, how, .unknown, .snapshotDiff, "no window change", "observe again")
    }

    private func typeInto(_ c: Candidate, _ t0: TimeInterval, text: String, placement: TextPlacement, elementId: String, observation: Observation) async -> ExecutionOutcome {
        guard let resolver, let r = await resolver.resolve(elementId: elementId, snapshotId: observation.snapshotId) else {
            return outcome(c, t0, .failed, "field \(elementId) is not in the current snapshot", .failed, .snapshotDiff, "", "re-observe")
        }
        guard !r.element.secure else { return outcome(c, t0, .failed, "secure field", .failed, .fieldValue, "", "") }
        let f = fresh(r)
        guard f.ok else { return outcome(c, t0, .failed, "stale field: \(f.why)", .failed, .snapshotDiff, f.why, "re-observe") }
        let app = AX.app(r.pid)
        // Focus the field: set AXFocused, else press it, else click its centre.
        if AXUIElementSetAttributeValue(r.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
            if !AX.press(r.ref), let frame = f.frame { let (cx, cy) = frame.center; Keys.click(at: CGPoint(x: cx, y: cy)) }
        }
        let focused = await waitFor(timeoutMs: 600) { () -> Bool? in
            guard let fe = AX.element(app, kAXFocusedUIElementAttribute) else { return nil }
            return CFEqual(fe, r.ref) ? true : nil
        }
        guard focused == true else { return outcome(c, t0, .failed, "could not focus the field", .failed, .fieldValue, "", "re-observe") }
        let before = AX.string(r.ref, kAXValueAttribute) ?? ""
        // A leading newline means "start a new line first" (a note body under its title); the
        // focused-field path does the same. Press Return in the now-focused target, then type.
        var text = text
        if text.hasPrefix("\n") {
            Keys.press(Keys.returnKey, pid: r.pid)
            try? await Task.sleep(for: .milliseconds(60))
            text = String(text.dropFirst())
        }
        let ref = r.ref
        let how = (await enter(text, into: ref, pid: r.pid, placement: placement, before: before) { AX.string(ref, kAXValueAttribute) ?? "" }) + " into '\(r.element.text)'"
        let after = await waitFor(timeoutMs: 800) { () -> String? in
            let v = AX.string(r.ref, kAXValueAttribute) ?? ""
            return self.typed(text, placement: placement, before: before, now: v) ? v : nil
        }
        if let after { return outcome(c, t0, .acknowledged, how, .verified, .fieldValue, String(after.suffix(80)), "") }
        return outcome(c, t0, .acknowledged, "text sent (\(how))", .unknown, .fieldValue, String((AX.string(r.ref, kAXValueAttribute) ?? "").suffix(80)), "observe again")
    }

    private func key(_ c: Candidate, _ t0: TimeInterval, _ code: CGKeyCode, name: String) async -> ExecutionOutcome {
        let app = Apps.frontmost()
        let beforeField = AX.focusedField(pid: app.pid)
        let beforeWin = AX.focusedWindow(AX.app(app.pid)).flatMap { AX.string($0, kAXRoleAttribute) }
        Keys.press(code, pid: app.pid)
        let changed = await waitFor(timeoutMs: 500) { () -> String? in
            let f = AX.focusedField(pid: app.pid)
            let front = Apps.frontmost()
            if front.bundleId != app.bundleId { return "frontmost app changed to \(front.name)" }
            if f != beforeField { return "focused field changed" }
            return nil
        }
        _ = beforeWin
        if let changed { return outcome(c, t0, .acknowledged, name, .verified, .snapshotDiff, changed, "") }
        return outcome(c, t0, .acknowledged, name, .unknown, .snapshotDiff, "no observable change", "observe again")
    }

    private func scroll(_ c: Candidate, _ t0: TimeInterval, direction: ScrollDirection, amount: ScrollAmount) async -> ExecutionOutcome {
        let app = Apps.frontmost()
        // Measured in Chrome: one line tick ≈ 40 px, so 18 lines ≈ one 700 px viewport.
        let lines = [ScrollAmount.little: 6, .page: 18, .end: 400][amount]! * (direction == .up ? -1 : 1)
        let window = AX.focusedWindow(AX.app(app.pid))
        let frame = window.flatMap(AX.frame) ?? Frame(x: 0, y: 0, width: 800, height: 600)
        // Slightly above centre: below the toolbar, inside the content, away from a bottom bar.
        let point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height * 0.45)
        let before = window.flatMap { AX.scrollPosition(window: $0, at: point) }
        Keys.scroll(lines: lines, at: point)
        guard let window, let before else {
            return outcome(c, t0, .acknowledged, "scroll \(lines) lines", .unknown, .snapshotDiff, "scroll position not readable", "")
        }
        let after = await waitFor(timeoutMs: 700) { () -> Double? in
            guard let now = AX.scrollPosition(window: window, at: point), abs(now - before) > 0.0005 else { return nil }
            return now
        }
        if let after { return outcome(c, t0, .acknowledged, "scroll \(lines) lines", .verified, .snapshotDiff, String(format: "scroll %.2f -> %.2f", before, after), "") }
        let atLimit = (direction == .down && before >= 0.999) || (direction == .up && before <= 0.001)
        return outcome(c, t0, .acknowledged, "scroll \(lines) lines", atLimit ? .verified : .unknown, .snapshotDiff,
                       atLimit ? "already at the \(direction == .up ? "top" : "bottom")" : String(format: "scroll position unchanged at %.2f", before), atLimit ? "" : "observe again")
    }

    private func goBack(_ c: Candidate, _ t0: TimeInterval) async -> ExecutionOutcome {
        let app = Apps.frontmost()
        guard Browser.isBrowser(app.bundleId) else {
            return outcome(c, t0, .failed, "front app is not a browser", .failed, .frontmostApp, app.name, "")
        }
        let before = chromeURL()
        // The toolbar Back button by AX first (its enabled state says whether there is history),
        // then the History > Back menu item, then Cmd+[.
        var how = "Cmd+["
        if let win = AX.focusedWindow(AX.app(app.pid)),
           let back = AX.find(in: win, maxNodes: 900, maxDepth: 8, where: { el, role in role == kAXButtonRole && (AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute) ?? "").lowercased() == "back" }) {
            // Right after a navigation the button enables a beat later than the page shows.
            let enabled = await waitFor(timeoutMs: 1500) { () -> Bool? in (AX.bool(back, kAXEnabledAttribute) ?? false) ? true : nil }
            if enabled != true {
                return outcome(c, t0, .acknowledged, "Back button disabled", .verified, .snapshotDiff, "nothing to go back to in this tab", "")
            }
            if AX.press(back) { how = "AX press Back" }
        }
        if how == "Cmd+[", let item = AX.menuItem(pid: app.pid, menu: "History", item: "Back"), AX.press(item) { how = "History > Back" }
        if how == "Cmd+[" { Keys.press(Keys.leftBracketKey, flags: .maskCommand, pid: app.pid) }
        // Back is not typed text, so the address bar is trustworthy here and moves first; the
        // document URL follows when the page commits. A slow page can take a few seconds.
        let docBefore = Browser.documentURL(pid: app.pid)
        if let after = await waitFor(timeoutMs: 5000, { () -> String? in
            if let d = Browser.documentURL(pid: app.pid), d != docBefore { return d }
            if let u = self.chromeURL(), u != before { return u }
            return nil
        }) {
            await Browser.waitForLoad(pid: app.pid)
            return outcome(c, t0, .acknowledged, how, .verified, .url, String(after.prefix(120)), "")
        }
        return outcome(c, t0, .acknowledged, how, .unknown, .url, before.map { String($0.prefix(120)) } ?? "", "observe again")
    }

    private func outcome(_ c: Candidate, _ t0: TimeInterval, _ status: DispatchStatus, _ detail: String, _ v: VerificationOutcome,
                         _ evidence: VerificationEvidence, _ observed: String, _ next: String) -> ExecutionOutcome {
        ExecutionOutcome(result: ActionResult(dispatchId: "", status: status, detail: detail, tookMs: (Mono.now() - t0) * 1000),
                         verification: Verification(dispatchId: "", expected: c.expectedPostcondition, observed: observed, outcome: v, evidence: evidence, nextStep: next))
    }
}
