import AppKit
import ApplicationServices
import Foundation
import JevCore

/// A live element reference for the executor; the id is only meaningful within its snapshot.
public struct ElementRef: @unchecked Sendable {
    public let element: Element
    public let ref: AXUIElement
    public let pid: pid_t
}

public protocol ElementResolving: Sendable {
    func resolve(elementId: String, snapshotId: String) async -> ElementRef?
}

/// Frontmost app, focused field, and the AX walk (Phase 4), cached for `snapshotTtlMs` and
/// invalidated after every action or on app activation / focus change. `warm()` refreshes in the
/// background after an invalidation so a decision reads a snapshot that is already fresh.
public actor MacPerception: Perceiving, ElementResolving {
    private var cached: Observation?
    private var refs: [String: AXUIElement] = [:]
    private var refsSnapshot = ""
    private var refsPid: pid_t = 0
    private let log: RunLog?
    private let walk: Bool
    private var warming: Task<Void, Never>?
    public private(set) var lastWalk: (nodes: Int, elements: Int, offscreen: Int, collapsed: Int, truncated: Bool, tookMs: Double)?

    public init(log: RunLog? = nil, walkElements: Bool = true) {
        self.log = log
        self.walk = walkElements && AXIsProcessTrusted()
    }

    public func observe() async -> Observation {
        if let c = cached, (Mono.now() - c.takenAt) * 1000 < Double(Config.snapshotTtlMs) { return c }
        return snapshot()
    }

    private func snapshot() -> Observation {
        let t0 = Mono.now()
        AX.callCount = 0
        let app = Apps.frontmost()
        let field = app.pid > 0 ? AX.focusedField(pid: app.pid) : nil
        var elements: [Element] = [], offscreen: [Element] = [], truncated = false
        var newRefs: [String: AXUIElement] = [:]
        if walk, app.pid > 0, !Config.denyApps.contains(app.bundleId) {
            let r = AXWalker.walk(pid: app.pid)
            elements = r.elements; offscreen = r.offscreen; truncated = r.truncated; newRefs = r.refs
            lastWalk = (r.nodes, r.elements.count, r.offscreen.count, r.collapsed, r.truncated, r.tookMs)
            log?.log("walk", ["nodes": .number(Double(r.nodes)), "elements": .number(Double(r.elements.count)), "offscreen": .number(Double(r.offscreen.count)),
                              "collapsed": .number(Double(r.collapsed)), "truncated": .bool(r.truncated), "took_ms": .number(r.tookMs)])
        }
        let host: String? = Browser.isBrowser(app.bundleId) ? Browser.currentURL(pid: app.pid).flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") } : nil
        // Menu-bar commands, read once per app while it stays in front (MenuBar caches); the
        // executor reads the enabled state at press time, since it changes faster than the cache.
        var menus: [MenuItem] = []
        if walk, app.pid > 0, !Config.denyApps.contains(app.bundleId) {
            for (i, e) in MenuBar.entries(pid: app.pid).enumerated() { menus.append(MenuItem(id: String(format: "m%02d", i + 1), path: e.title)) }
        }
        let obs = Observation(snapshotId: Ident.make("s"), takenAt: Mono.now(), app: app, focusedField: field,
                              elements: elements, offscreen: offscreen, pageHost: host, menus: menus, truncated: truncated, tookMs: (Mono.now() - t0) * 1000)
        log?.recordSnapshot(axCalls: AX.callCount)
        cached = obs
        refs = newRefs; refsSnapshot = obs.snapshotId; refsPid = app.pid
        return obs
    }

    public func invalidate() async {
        cached = nil
    }

    /// Invalidate and refresh in the background (observer-driven, plan section 5).
    public func warm() {
        cached = nil
        warming?.cancel()
        warming = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))   // let the UI settle after the event
            guard !Task.isCancelled, let self else { return }
            _ = await self.observe()
        }
    }

    public func resolve(elementId: String, snapshotId: String) async -> ElementRef? {
        guard snapshotId == refsSnapshot, let ref = refs[elementId],
              let e = (cached?.elements ?? []).first(where: { $0.id == elementId }) ?? (cached?.offscreen ?? []).first(where: { $0.id == elementId })
        else { return nil }
        return ElementRef(element: e, ref: ref, pid: refsPid)
    }
}

/// Keeps perception warm: app activation and AX focus/window notifications on the frontmost app
/// trigger a background refresh. Main-thread only (AXObserver needs the main run loop).
@MainActor
public final class PerceptionWatcher {
    private let perception: MacPerception
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var tokens: [NSObjectProtocol] = []

    public init(perception: MacPerception) { self.perception = perception }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            Task { @MainActor in self?.attach(pid: pid); await self?.perception.warm() }
        })
        attach(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    public func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        detach()
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil; observedPid = 0
    }

    private func attach(pid: pid_t) {
        guard pid != observedPid, pid > 0, AXIsProcessTrusted() else { return }
        detach()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<PerceptionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { await me.perception.warm() }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let o = obs else { return }
        let app = AX.app(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(o, app, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = o; observedPid = pid
    }
}
