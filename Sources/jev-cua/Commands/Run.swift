import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import JevCore
import JevMac
import os

/// `jev-cua run [--provider dictation|sfspeech] [--ui notch|pill] [--hotkey ctrl+alt+j] [--dry-run] [--speak|--no-speak] [--no-overlay] [--redact] [--no-cache] [--quiet]`
/// Live voice control (plan Phase 3): recognizer -> VoiceLoop -> CommandSession -> executor, with
/// the notch overlay (or the pill), a status-bar item, spoken feedback, and three stop paths
/// (kill phrase, ⌃⌥Space, mouse to the top-left corner).
enum Run {
    /// Everything that must outlive `setup`: since `main` is synchronous, `setup` returns and its
    /// locals would be freed while Carbon and AXObserver callbacks still point at them (a
    /// SIGSEGV in the hot key handler on 2026-09-20).
    @MainActor
    final class Live {
        let log: RunLog
        let decider: any JevDeciding
        let perception: MacPerception
        let executor: MacExecutor
        let audio: AudioInput
        let speaker: Speaker
        let ui: RunUI
        let session: CommandSession
        let loop: VoiceLoop
        let stopper: Stopper
        let watcher: PerceptionWatcher
        init(log: RunLog, decider: any JevDeciding, perception: MacPerception, executor: MacExecutor, audio: AudioInput, speaker: Speaker,
             ui: RunUI, session: CommandSession, loop: VoiceLoop, stopper: Stopper, watcher: PerceptionWatcher) {
            self.log = log; self.decider = decider; self.perception = perception; self.executor = executor; self.audio = audio
            self.speaker = speaker; self.ui = ui; self.session = session; self.loop = loop; self.stopper = stopper; self.watcher = watcher
        }
    }
    @MainActor static var live: Live?

    /// Sets everything up; the caller (Entry.runUI) owns the AppKit run loop.
    @MainActor
    static func setup(_ args: Args) async throws {

        // Grants. Microphone and Speech prompt here; Accessibility only warns (System Settings).
        let mic = await Permissions.requestMicrophone()
        guard mic == .authorized else { throw UsageError("microphone permission is \(mic.rawValue); run scripts/app-run.sh doctor --prompt") }
        let speech = await Permissions.requestSpeech()
        guard speech == .authorized else { throw UsageError("speech recognition permission is \(speech.rawValue)") }
        let ax = Permissions.accessibility(prompt: false) == .authorized
        if !ax { FileHandle.standardError.write(Data("warning: Accessibility not granted; focused fields and verifications will be unknown\n".utf8)) }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let log = try RunLog(runsRoot: cwd.appending(path: "runs"), redact: args.flag("redact"))
        // Shorter than the CLI's 5 s: a decision older than this is stale, and an outage should
        // show at once rather than as commands that silently never happen.
        let live = try JevClient(timeout: Config.liveDecisionTimeoutS, maxRetryDelayMs: Config.liveRetryDelayMs)
        let decider: any JevDeciding = args.flag("no-cache") ? live : JevCache(path: JevCache.livePath(cwd), live: live)
        let perception = MacPerception(log: log)
        let executor = MacExecutor(mode: args.flag("dry-run") ? .dryRun : .live, log: log, resolver: perception)

        let audio = AudioInput()
        let speakEnabled = args.flag("no-speak") ? false : (args.flag("speak") ? true : Speaker.enabledByDefault)
        let speaker = Speaker(audio: audio, enabled: speakEnabled)
        let style: RunUI.Style = args.flag("no-overlay") ? .none : (RunUI.Style(rawValue: args.string("ui") ?? "notch") ?? .notch)
        let ui = RunUI(style: style, dryRun: args.flag("dry-run"), speaker: speaker)
        ui.trace = { kind, data in log.log("ui", { var d = data; d["what"] = .string(kind); return d }()) }
        let printer = args.flag("quiet") ? nil : EventPrinter()

        var cfg = CommandSession.Config()
        cfg.installedApps = InstalledApps.names()
        cfg.runningApps = Set(NSWorkspaceRunning.names())
        let session = CommandSession(decider: decider, perception: perception, executor: executor, log: log, config: cfg) { ev in
            printer?.print(ev)
            if let phrase = Speaker.phrase(for: ev) { speaker.say(phrase) }
            if let chime = Speaker.chime(for: ev) { speaker.chime(chime) }
            Task { @MainActor in ui.apply(ev) }
        }

        let provider: any SpeechProvider
        switch args.string("provider") ?? "dictation" {
        case "sfspeech": provider = try SFSpeechProvider(audio: audio)
        case "transcriber": provider = SpeechTranscriberProvider(audio: audio, module: .transcriber(fast: false))
        default: provider = SpeechTranscriberProvider(audio: audio, module: .dictation)
        }
        let loop = VoiceLoop(provider: provider, audio: audio, session: session) { st in Task { @MainActor in ui.apply(st) } }
        ui.attach(loop: loop, session: session)
        // Hovering the notch suggests a phrase for the app in front (item 3d).
        ui.hoverHint = { Suggestions.phrases(bundleId: Apps.frontmost().bundleId, pageHost: nil).randomElement() }

        let stopper = Stopper(loop: loop, session: session, speaker: speaker, log: log)
        stopper.install(hotKeySpec: args.string("hotkey"))
        ui.hotKeyDisplay = stopper.hotKey.display
        let watcher = PerceptionWatcher(perception: perception)
        watcher.start()

        try await loop.start()
        // Hold-to-talk (item 3c): the flag wins, else the menu's last choice.
        let hold = args.flag("hold-to-talk") || (!args.flag("always-on") && UserDefaults.standard.bool(forKey: RunUI.holdToTalkKey))
        if hold { await loop.setHoldToTalk(true) }
        let keys = hold ? "hold \(stopper.hotKey.display) to talk" : "\(stopper.hotKey.display) pauses"
        print("listening (\(provider.name)); \(keys), mouse to the top-left corner stops, say \"stop\" to cancel, \"what can I say?\" for examples; log \(log.directory.lastPathComponent)")
        ui.show()

        Run.live = Live(log: log, decider: decider, perception: perception, executor: executor, audio: audio, speaker: speaker,
                        ui: ui, session: session, loop: loop, stopper: stopper, watcher: watcher)

        // Quit from the status menu: tear down in order, then leave the run loop.
        ui.onQuit = {
            Task {
                await loop.stop()
                await MainActor.run { watcher.stop() }
                log.close()
                if let cache = decider as? JevCache { try? cache.save() }
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

/// Global stop paths: ⌃⌥Space toggles pause; the pointer parked in the top-left corner for
/// 300 ms pauses and cancels (a physical panic path that needs no permissions).
final class Stopper: @unchecked Sendable {
    let loop: VoiceLoop
    let session: CommandSession
    let speaker: Speaker
    let log: RunLog
    private var hotKeyRef: EventHotKeyRef?
    private var monitor: Any?
    private var cornerSince: TimeInterval?
    private var timer: Timer?
    private var lastToggle: TimeInterval = 0

    init(loop: VoiceLoop, session: CommandSession, speaker: Speaker, log: RunLog) { self.loop = loop; self.session = session; self.speaker = speaker; self.log = log }

    /// A shortcut like "ctrl+alt+j" or "cmd+shift+space": Carbon modifiers, virtual key code,
    /// and the NSEvent flags for the monitor. Letters, digits, space, return, escape, F-keys.
    struct HotKey: Sendable {
        var carbonModifiers: UInt32
        var flags: NSEvent.ModifierFlags
        var keyCode: UInt32
        var display: String

        static let defaultSpec = "ctrl+alt+j"

        static func parse(_ spec: String) -> HotKey? {
            let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let keyName = parts.last else { return nil }
            var mods: UInt32 = 0
            var flags: NSEvent.ModifierFlags = []
            var glyphs = ""
            for m in parts.dropLast() {
                switch m {
                case "ctrl", "control", "⌃": mods |= UInt32(controlKey); flags.insert(.control); glyphs += "⌃"
                case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey); flags.insert(.option); glyphs += "⌥"
                case "shift", "⇧": mods |= UInt32(shiftKey); flags.insert(.shift); glyphs += "⇧"
                case "cmd", "command", "⌘": mods |= UInt32(cmdKey); flags.insert(.command); glyphs += "⌘"
                default: return nil
                }
            }
            let letters = "asdfhgzxcv§bqweryt123465=97-80]ou[ip\u{0D}lj'k;\\,/nm."   // kVK_ANSI_* order
            let codes: [String: Int] = ["space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape, "tab": kVK_Tab,
                                        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
                                        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12]
            var code: Int?
            if let c = codes[keyName] { code = c }
            else if keyName.count == 1, let i = letters.firstIndex(of: Character(keyName)) { code = letters.distance(from: letters.startIndex, to: i) }
            guard let code, mods != 0 else { return nil }
            return HotKey(carbonModifiers: mods, flags: flags, keyCode: UInt32(code), display: glyphs + (keyName.count == 1 ? keyName.uppercased() : keyName.capitalized))
        }
    }

    private(set) var hotKey = HotKey.parse(HotKey.defaultSpec)!

    @MainActor
    func install(hotKeySpec: String?) {
        if let spec = hotKeySpec, let hk = HotKey.parse(spec) { hotKey = hk }
        // Carbon hot key (no Input Monitoring needed) plus a global NSEvent monitor (needs
        // Accessibility, which the app has); either delivers, a 300 ms debounce keeps a double
        // delivery from toggling twice, and the log says which path fired. Neither sees a key
        // that another app's event tap swallows first.
        // Presses and releases: a release matters for hold-to-talk (item 3c).
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<Stopper>.fromOpaque(userData).takeUnretainedValue()
            let down = event.map { GetEventKind($0) == UInt32(kEventHotKeyPressed) } ?? true
            Task { if down { await me.keyDown(source: "carbon") } else { await me.keyUp(source: "carbon") } }
            return noErr
        }, 2, &specs, selfPtr, nil)
        let id = EventHotKeyID(signature: OSType(0x4A455643) /* JEVC */, id: 1)
        let registered = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        let wanted = hotKey
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard ev.keyCode == UInt16(wanted.keyCode) else { return }
            if ev.type == .keyDown {
                guard !ev.isARepeat, ev.modifierFlags.intersection([.control, .option, .shift, .command]) == wanted.flags else { return }
                Task { await self?.keyDown(source: "monitor") }
            } else {
                Task { await self?.keyUp(source: "monitor") }   // whatever the modifiers do: they often come up first
            }
        }
        log.log("hotkey_install", ["hotkey": .string(hotKey.display), "carbon_handler": .number(Double(installed)), "carbon_register": .number(Double(registered)),
                                   "monitor": .bool(monitor != nil)])

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollHeldKey(wanted.keyCode)
            let p = NSEvent.mouseLocation
            let inCorner = NSScreen.screens.contains { s in p.x <= s.frame.minX + 2 && p.y >= s.frame.maxY - 2 }
            if inCorner {
                if let since = cornerSince, Mono.now() - since >= 0.3 { cornerSince = nil; Task { await self.panic() } }
                else if cornerSince == nil { cornerSince = Mono.now() }
            } else { cornerSince = nil }
        }
    }

    func hotKeyHit(source: String) async {
        let now = Mono.now()
        log.log("hotkey", ["source": .string(source), "debounced": .bool(now - lastToggle < 0.3)])
        guard now - lastToggle >= 0.3 else { return }
        lastToggle = now
        await togglePause()
    }

    func togglePause() async {
        let paused = loop.isPaused
        await loop.setPaused(!paused)
        // A chime, not "Listening": speech mutes the mic for about a second (item 3a).
        speaker.chime(paused ? .listening : .paused)
    }

    // MARK: Hold-to-talk (item 3c)

    /// Whether the key is held, and whether the key-state poll can see it. Both delivery paths
    /// (Carbon and the monitor) report every press and release, so changes go through the lock.
    private let hold = OSAllocatedUnfairLock(initialState: (held: false, since: 0.0, pollUsable: true, misses: 0))

    func keyDown(source: String) async {
        guard loop.isHoldToTalk else { await hotKeyHit(source: source); return }   // toggle mode, as before
        let began = hold.withLock { h -> Bool in
            guard !h.held else { return false }
            h.held = true; h.since = Mono.now(); h.misses = 0
            return true
        }
        guard began else { return }
        // Can the poll read the key? It is down right now, so a "not down" means it cannot.
        if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hotKey.keyCode)) { hold.withLock { $0.pollUsable = false } }
        log.log("hotkey", ["source": .string(source), "hold": .string("down")])
        speaker.chime(.listening)
        await loop.holdBegan()
    }

    func keyUp(source: String) async {
        guard loop.isHoldToTalk else { return }
        let ended = hold.withLock { h -> Bool in
            guard h.held else { return false }
            h.held = false
            return true
        }
        guard ended else { return }
        log.log("hotkey", ["source": .string(source), "hold": .string("up")])
        // No chime here: people let go on the last syllable, and a chime would mute it.
        await loop.holdEnded()
    }

    /// A release both paths missed (a key-up swallowed by another app's event tap) would leave
    /// the mic open: the timer checks that a held key is still down.
    private func pollHeldKey(_ keyCode: UInt32) {
        let released = hold.withLock { h -> Bool in
            guard h.held, h.pollUsable, Mono.now() - h.since > 0.3 else { return false }
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) { h.misses = 0; return false }
            h.misses += 1
            return h.misses >= 2
        }
        if released { Task { await keyUp(source: "poll") } }
    }

    func panic() async {
        guard !loop.isPaused else { return }
        speaker.stop()
        await session.cancelAll(reason: "mouse corner")
        await loop.setPaused(true)
        speaker.say("Stopped")
    }
}

/// What the overlay shows. Filled by RunUI from loop status and session events.
struct OverlayModel: Equatable {
    struct Chip: Equatable {
        enum State { case running, verified, unknown, failed }
        var label: String
        var state: State
    }
    var rawText = ""
    var consumed = ""
    var listening = false
    var micLoud = false
    var level: Float = 0
    var statusLine = ""
    var pending: String?
    var badgeCount = 0
    var chips: [Chip] = []
    var dryRun = false
    var hotKey = "⌃⌥J"
    /// The words may be addressed to the computer (a decision other than chatter), or "Show all
    /// speech" is on. The transcript opens the notch only then (item 1c).
    var engaged = false
    /// The action a clause will run once the words stop, drawn as a ghost chip (item 1b).
    var armed: String?
    /// Jev is unreachable, in a few words (item 3b).
    var offline: String?
    /// Example phrases answering "what can I say?" (item 3d).
    var help: [String]?
    /// A short message that is not a decision: an undo that cannot run, a lapsed confirmation.
    var notice: String?
    var holdToTalk = false
    /// Paused by the user. Between holds, hold-to-talk is idle, not paused: results still show.
    var paused: Bool { !listening && !holdToTalk }
    /// True while there is something to show; the notch collapses after a short delay when this
    /// goes false.
    var active: Bool {
        (engaged && !rawText.isEmpty) || pending != nil || badgeCount > 0 || !chips.isEmpty || armed != nil || help != nil || notice != nil
            || (offline != nil && !rawText.isEmpty)
    }
}

@MainActor
protocol OverlayRenderer: AnyObject {
    func render(_ m: OverlayModel)
    func show()
    func hide()
    var isVisible: Bool { get }
}

/// Overlay state, the status-bar item, and the badge overlay (plan Phase 3, section 8.3).
/// The transcript itself is drawn by a renderer: the notch (default) or the pill (`--ui pill`).
@MainActor
final class RunUI: NSObject {
    enum Style: String { case notch, pill, none }
    static let holdToTalkKey = "holdToTalk"
    static let showAllSpeechKey = "showAllSpeech"
    private var renderer: (any OverlayRenderer)?
    private var statusItem: NSStatusItem?
    let badges = BadgeOverlay()
    private let speaker: Speaker
    private weak var loop: VoiceLoop?
    private weak var session: CommandSession?
    var onQuit: (() -> Void)?
    var hotKeyDisplay = "⌃⌥J" { didSet { model.hotKey = hotKeyDisplay } }
    var trace: ((String, [String: JSONValue]) -> Void)? { didSet { (renderer as? NotchWindow)?.trace = trace } }
    /// A phrase to suggest when the pointer rests on the notch (item 3d).
    var hoverHint: (() -> String?)? { didSet { (renderer as? NotchWindow)?.hoverHint = hoverHint } }
    private var model = OverlayModel()
    private var chipsUtterance = ""
    /// "Show all speech": chatter opens the notch too (the old behavior), to watch what it hears.
    private var showAllSpeech = UserDefaults.standard.bool(forKey: RunUI.showAllSpeechKey)
    /// The status menu's "Recent actions", newest first.
    private var recent: [(label: String, state: OverlayModel.Chip.State, at: Date)] = []
    /// The action running now, and the last one that can be undone (the session's rule, mirrored
    /// here so the menu item can say what it would undo).
    private var running: (label: String, action: Action)?
    private var undoLabel: String?
    private var helpClear: Task<Void, Never>?
    private var noticeClear: Task<Void, Never>?
    private var statusKey = ""

    init(style: Style, dryRun: Bool, speaker: Speaker) {
        self.speaker = speaker
        super.init()
        model.dryRun = dryRun
        model.engaged = showAllSpeech
        switch style {
        case .notch: renderer = NotchWindow()
        case .pill: renderer = PillWindow()
        case .none: renderer = nil
        }
        buildStatusItem()
    }

    func attach(loop: VoiceLoop, session: CommandSession) {
        self.loop = loop; self.session = session
        (renderer as? NotchWindow)?.onClick = { [weak self] in self?.toggleListening() }
    }

    func show() { renderer?.show(); render() }

    // MARK: Inputs

    func apply(_ st: VoiceLoop.Status) {
        model.rawText = st.text; model.listening = st.listening; model.micLoud = st.micLoud; model.level = st.level
        model.holdToTalk = st.holdToTalk
        if st.text.isEmpty { model.consumed = "" }
        if st.utteranceId != chipsUtterance, !st.text.isEmpty {
            // A new utterance: the last one's chips, status, and examples make way once new words
            // arrive, and the notch waits to hear something like a command before it opens.
            chipsUtterance = st.utteranceId
            model.chips = []; model.statusLine = ""; model.help = nil
            model.engaged = showAllSpeech
        }
        render()
    }

    func apply(_ ev: SessionEvent) {
        switch ev {
        case .transcript(_, _, let c, _): model.consumed = c
        case .deciding: break   // routine and never shown: at one every ~110 ms it read as flicker
        case .decided(let d, _, _):
            if Feedback.engages(d.outcome) { model.engaged = true }
            if let line = Feedback.statusLine(for: d.outcome, reasons: d.reasons) { model.statusLine = line }
        case .armed(let c): model.armed = c?.humanLabel
        case .dispatched(_, let c):
            model.armed = nil   // the running chip takes the ghost chip's place
            model.engaged = true
            model.statusLine = ""   // the chip carries it; the verification fills this in
            model.chips.append(.init(label: c.humanLabel, state: .running))
            if model.chips.count > 4 { model.chips.removeFirst() }
            badges.show([]); model.badgeCount = 0
            running = (c.humanLabel, c.action)
            recent.insert((c.humanLabel, .running, Date()), at: 0)
            if recent.count > 8 { recent.removeLast() }
        case .executed(_, let o):
            model.statusLine = "\(o.result.detail)\(o.verification.observed.isEmpty ? "" : " · \(o.verification.observed)")"
            let state: OverlayModel.Chip.State = o.verification.outcome == .verified ? .verified : (o.verification.outcome == .failed ? .failed : .unknown)
            if let i = model.chips.lastIndex(where: { $0.state == .running }) { model.chips[i].state = state }
            if let i = recent.firstIndex(where: { $0.state == .running }) { recent[i].state = state }
            if let r = running {
                let ok = o.result.status == .acknowledged && o.verification.outcome != .failed
                undoLabel = ok && Undo.inverse(of: r.action, detail: o.result.detail) != nil ? r.label : nil
            }
            running = nil
        case .pendingConfirmation(let c): model.pending = c?.humanLabel
        case .disambiguation(let els): badges.show(els ?? []); model.badgeCount = els?.count ?? 0
        case .cancelled(let r):
            model.statusLine = "cancelled: \(r)"; model.consumed = ""; model.chips = []; model.armed = nil
            badges.show([]); model.badgeCount = 0
        case .error(let m): model.statusLine = "error: \(m)"
        case .offline(let why): model.offline = why
        case .help(let phrases): show(help: phrases)
        case .notice(let m): show(notice: m)
        }
        render()
    }

    private func show(help phrases: [String]) {
        model.help = phrases
        helpClear?.cancel()
        helpClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.model.help = nil; self.render()
        }
    }

    private func show(notice text: String) {
        model.notice = text
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.model.notice = nil; self.render()
        }
    }

    private func render() {
        renderer?.render(model)
        let state: StatusIcon.State = model.offline != nil ? .offline : (!model.listening ? .paused : (model.micLoud ? .speaking : .listening))
        let tip: String = switch state {
        case .offline: "jev-cua: can't reach Jev (\(model.offline ?? ""))"
        case .paused: model.holdToTalk ? "jev-cua: hold \(hotKeyDisplay) to talk" : "jev-cua: paused"
        default: "jev-cua: \(state.rawValue)"
        }
        let key = "\(state.rawValue)|\(tip)"
        if key != statusKey {
            statusKey = key
            statusItem?.button?.image = StatusIcon.image(for: state)
            statusItem?.button?.toolTip = tip + (model.dryRun ? " (dry run)" : "")
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image(for: .listening)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "jev-cua"
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector?, tag: Int = 0, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self; i.tag = tag
            menu.addItem(i)
            return i
        }
        _ = add("Listening (\(hotKeyDisplay))", #selector(toggleListening), tag: 1)
        _ = add("Hold \(hotKeyDisplay) to talk", #selector(toggleHold), tag: 4)
        menu.addItem(.separator())
        _ = add("What can I say?", #selector(showExamples))
        add("Recent actions", nil, tag: 6).submenu = NSMenu()
        _ = add("Undo last action", #selector(undoLast), tag: 7)
        menu.addItem(.separator())
        _ = add("Spoken feedback", #selector(toggleSpeak), tag: 2)
        _ = add("Sounds", #selector(toggleSounds), tag: 5)
        _ = add("Show overlay", #selector(toggleOverlay), tag: 3)
        _ = add("Show all speech", #selector(toggleShowAll), tag: 8)
        menu.addItem(.separator())
        _ = add("Open runs folder", #selector(openRuns))
        menu.addItem(.separator())
        _ = add("Quit jev-cua", #selector(quit), key: "q")
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleListening() {
        Task { [weak self] in
            guard let self, let loop = self.loop else { return }
            // Hold-to-talk has nothing to toggle (the key is held to talk): a click shows examples.
            if loop.isHoldToTalk { await self.session?.showHelp(); return }
            let paused = loop.isPaused
            await loop.setPaused(!paused)
            self.speaker.chime(paused ? .listening : .paused)
        }
    }
    @objc private func toggleHold() {
        Task { [weak self] in
            guard let self, let loop = self.loop else { return }
            let on = !loop.isHoldToTalk
            await loop.setHoldToTalk(on)
            UserDefaults.standard.set(on, forKey: Self.holdToTalkKey)
            self.speaker.chime(on ? .paused : .listening)
        }
    }
    @objc private func showExamples() { Task { [weak self] in await self?.session?.showHelp() } }
    @objc private func undoLast() { Task { [weak self] in await self?.session?.undoLast() } }
    @objc private func toggleSpeak() { speaker.enabled.toggle() }
    @objc private func toggleSounds() { speaker.soundsEnabled.toggle() }
    @objc private func toggleOverlay() { guard let r = renderer else { return }; r.isVisible ? r.hide() : r.show() }
    @objc private func toggleShowAll() {
        showAllSpeech.toggle()
        UserDefaults.standard.set(showAllSpeech, forKey: Self.showAllSpeechKey)
        if showAllSpeech { model.engaged = true }
        render()
    }
    @objc private func openRuns() { NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "runs")) }
    @objc private func quit() { onQuit?() }

    static func mark(_ s: OverlayModel.Chip.State) -> String {
        switch s {
        case .running: "▶"
        case .verified: "✓"
        case .unknown: "?"
        case .failed: "✗"
        }
    }

    static func ago(_ d: Date) -> String {
        let s = max(0, Int(-d.timeIntervalSinceNow))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}

extension RunUI: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let hold = model.holdToTalk
        if let l = menu.item(withTag: 1) {
            l.title = hold ? "Listening (while \(hotKeyDisplay) is held)" : "Listening (\(hotKeyDisplay))"
            l.state = model.listening && !hold ? .on : .off
            l.isEnabled = !hold
        }
        if let h = menu.item(withTag: 4) { h.title = "Hold \(hotKeyDisplay) to talk"; h.state = hold ? .on : .off }
        menu.item(withTag: 2)?.state = speaker.enabled ? .on : .off
        menu.item(withTag: 5)?.state = speaker.soundsEnabled ? .on : .off
        menu.item(withTag: 3)?.state = (renderer?.isVisible ?? false) ? .on : .off
        menu.item(withTag: 8)?.state = showAllSpeech ? .on : .off
        if let u = menu.item(withTag: 7) {
            u.title = undoLabel.map { "Undo \($0)" } ?? "Undo last action"
            u.isEnabled = undoLabel != nil
        }
        if let sub = menu.item(withTag: 6)?.submenu {
            sub.removeAllItems()
            func row(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
            if recent.isEmpty { sub.addItem(row("Nothing yet")) }
            for r in recent { sub.addItem(row("\(Self.mark(r.state))  \(r.label)  ·  \(Self.ago(r.at))")) }
        }
    }
}

/// The original bottom-center pill (`--ui pill`).
@MainActor
final class PillWindow: OverlayRenderer {
    private let panel: NSPanel
    private let transcriptField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 84), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let fx = NSVisualEffectView(frame: p.contentView!.bounds)
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 20
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(fx)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        transcriptField.translatesAutoresizingMaskIntoConstraints = false
        transcriptField.lineBreakMode = .byTruncatingHead
        transcriptField.maximumNumberOfLines = 2
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        fx.addSubview(dot); fx.addSubview(transcriptField); fx.addSubview(statusField)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12), dot.heightAnchor.constraint(equalToConstant: 12),
            dot.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: transcriptField.centerYAnchor),
            transcriptField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            transcriptField.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -18),
            transcriptField.topAnchor.constraint(equalTo: fx.topAnchor, constant: 14),
            statusField.leadingAnchor.constraint(equalTo: transcriptField.leadingAnchor),
            statusField.trailingAnchor.constraint(equalTo: transcriptField.trailingAnchor),
            statusField.topAnchor.constraint(equalTo: transcriptField.bottomAnchor, constant: 6),
            statusField.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -12),
        ])
        panel = p
        layout()
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var debugPanel: NSPanel { panel }

    func render(_ m: OverlayModel) {
        transcriptField.attributedStringValue = OverlayText.transcript(m, size: 20, bright: .labelColor, dim: .tertiaryLabelColor)
        if let help = m.help, m.rawText.isEmpty { transcriptField.attributedStringValue = OverlayText.help(help, size: 18, bright: .labelColor, dim: .tertiaryLabelColor) }
        var s = OverlayText.compactEvidence(m.notice ?? m.statusLine)
        if let armed = m.armed { s = "⋯ \(armed)  (when you stop talking)" }
        if let why = m.offline { s = "can't reach Jev · \(why)" }
        if let pending = m.pending { s = "confirm? \(pending)   (say \"confirm\" or \"cancel\")" }
        if m.badgeCount > 0 { s = "which one? say a number, 1 to \(m.badgeCount)" }
        if m.dryRun { s = "[dry run] " + s }
        statusField.stringValue = s
        dot.layer?.backgroundColor = OverlayText.dotColor(m).cgColor
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = min(760, screen.visibleFrame.width - 80)
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = max(72, (panel.contentView?.fittingSize.height ?? 84))
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 48, width: width, height: height), display: true)
    }
}

enum OverlayText {
    @MainActor
    static func transcript(_ m: OverlayModel, size: CGFloat, bright: NSColor, dim: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let dimA: [NSAttributedString.Key: Any] = [.foregroundColor: dim, .font: NSFont.systemFont(ofSize: size, weight: .medium)]
        let brightA: [NSAttributedString.Key: Any] = [.foregroundColor: bright, .font: NSFont.systemFont(ofSize: size, weight: .medium)]
        if !m.consumed.isEmpty, let range = m.rawText.range(of: m.consumed, options: [.caseInsensitive, .anchored]) {
            text.append(NSAttributedString(string: String(m.rawText[..<range.upperBound]), attributes: dimA))
            text.append(NSAttributedString(string: String(m.rawText[range.upperBound...]), attributes: brightA))
        } else {
            let placeholder = m.listening ? "Listening…" : (m.holdToTalk ? "Hold \(m.hotKey) to talk" : "Paused")
            text.append(NSAttributedString(string: m.rawText.isEmpty ? placeholder : m.rawText, attributes: m.rawText.isEmpty ? dimA : brightA))
        }
        return text
    }

    /// "Try “scroll down” · “go back” · …": the answer to "what can I say?".
    @MainActor
    static func help(_ phrases: [String], size: CGFloat, bright: NSColor, dim: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Try  ", attributes: [.foregroundColor: dim, .font: NSFont.systemFont(ofSize: size, weight: .medium)])
        text.append(NSAttributedString(string: phrases.map { "“\($0)”" }.joined(separator: "  ·  "),
                                       attributes: [.foregroundColor: bright, .font: NSFont.systemFont(ofSize: size, weight: .medium)]))
        return text
    }

    /// Evidence for the overlay: a URL becomes its host and the start of its path
    /// ("en.wikipedia.org/w/…"); the full string stays in the run log.
    static func compactEvidence(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s'"]+"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            let raw = String(s[r])
            let short: String = {
                guard let u = URL(string: raw), let host = u.host else { return String(raw.prefix(40)) + "…" }
                let h = host.replacingOccurrences(of: "www.", with: "")
                let path = u.path
                guard path.count > 1 else { return h }
                let first = path.split(separator: "/").first.map(String.init) ?? ""
                return h + "/" + first + (path.split(separator: "/").count > 1 || u.query != nil ? "/…" : "")
            }()
            out.replaceSubrange(Range(m.range, in: out)!, with: short)
        }
        return out
    }

    /// Orange while Jev is unreachable, yellow while paused, dim white between holds, green while
    /// listening (bright while the mic is loud, so the folded notch still shows it hears you).
    static func dotColor(_ m: OverlayModel) -> NSColor {
        if m.offline != nil { return .systemOrange }
        if m.paused { return .systemYellow }
        if !m.listening { return NSColor.white.withAlphaComponent(0.55) }
        return m.micLoud ? .systemGreen : NSColor.systemGreen.withAlphaComponent(0.7)
    }
}

/// Numbered badges at element frames while a `disambiguate` decision waits for a spoken number
/// (plan Phase 4). AX frames use a top-left origin on the primary display; AppKit uses bottom-left.
@MainActor
final class BadgeOverlay {
    private var panels: [NSPanel] = []

    func show(_ elements: [Element]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        guard !elements.isEmpty, let primary = NSScreen.screens.first else { return }
        let screenHeight = primary.frame.height
        for (i, e) in elements.prefix(9).enumerated() {
            let size: CGFloat = 26
            let x = CGFloat(e.frame.x) - 4
            let y = screenHeight - CGFloat(e.frame.y) - size + 4
            let p = NSPanel(contentRect: NSRect(x: x, y: y, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.systemOrange.cgColor
            v.layer?.cornerRadius = size / 2
            v.layer?.borderColor = NSColor.white.cgColor
            v.layer?.borderWidth = 2
            let label = NSTextField(labelWithString: "\(i + 1)")
            label.font = .systemFont(ofSize: 14, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 3, width: size, height: 18)
            v.addSubview(label)
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
        }
    }
}


/// Menu-bar icon: an SF Symbol rendered as a template image, so it follows the menu bar's light
/// or dark appearance. Listening = a microphone; speaking = a waveform (the mic is above the
/// loud threshold); paused = a crossed microphone; offline = the network warning.
enum StatusIcon {
    enum State: String { case listening, speaking, paused, offline }

    @MainActor
    static func image(for state: State) -> NSImage? {
        let name: String
        switch state {
        case .listening: name = "mic"
        case .speaking: name = "waveform"
        case .paused: name = "mic.slash"
        case .offline: name = "wifi.exclamationmark"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let img = (NSImage(systemSymbolName: name, accessibilityDescription: "jev-cua \(state.rawValue)")
                         ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "jev-cua \(state.rawValue)"))?.withSymbolConfiguration(config) else { return nil }
        img.isTemplate = true
        return img
    }
}
