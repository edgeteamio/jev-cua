import Foundation

// Core contracts (NEW_COMBINED_PLAN.md section 4). Everything is Codable and Sendable so it
// serializes into run logs and replay fixtures unchanged. Code, not the model, owns every
// field here: Jev only ever returns an option id from a set that code built.

// MARK: - Utterance

public struct Utterance: Codable, Sendable, Equatable {
    public var id: String
    /// The recognizer's utterance. Virtual continuations share it and get ids like "<id>+1".
    public var physicalId: String
    public var revision: Int
    /// Raw recognizer text. Never normalized; spans index into this.
    public var rawText: String
    public var isFinal: Bool
    public var startedAt: TimeInterval
    public var updatedAt: TimeInterval
    /// Raw text already acted on in this breath. Later words start a new command.
    public var consumedPrefix: String
    /// Increments when the intent option changes between revisions; in-flight decisions from
    /// an older epoch are discarded.
    public var intentEpoch: Int

    public init(id: String, physicalId: String, revision: Int, rawText: String, isFinal: Bool,
                startedAt: TimeInterval, updatedAt: TimeInterval, consumedPrefix: String = "", intentEpoch: Int = 0) {
        self.id = id; self.physicalId = physicalId; self.revision = revision; self.rawText = rawText
        self.isFinal = isFinal; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.consumedPrefix = consumedPrefix; self.intentEpoch = intentEpoch
    }
}

// MARK: - Observation

public struct Frame: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
}

public struct Element: Codable, Sendable, Equatable {
    public var id: String            // "e01".."e99", reading order
    public var role: String          // normalised: button, link, textbox, row, tab, ...
    public var text: String          // <= 60 chars
    public var `where`: String       // 3x3 grid word: "top-left", "center", ...
    public var editable: Bool
    public var secure: Bool
    public var frame: Frame
    /// The named list, table, or group this element sits in ("Folders"), when the app names it.
    public var container: String?

    public init(id: String, role: String, text: String, where: String, editable: Bool, secure: Bool, frame: Frame, container: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.where = `where`
        self.editable = editable; self.secure = secure; self.frame = frame; self.container = container
    }
}

public struct FocusedField: Codable, Sendable, Equatable {
    public var role: String
    public var label: String?
    public var placeholder: String?
    public var valuePreview: String?   // <= 80 chars
    public var secure: Bool
    public init(role: String, label: String? = nil, placeholder: String? = nil, valuePreview: String? = nil, secure: Bool = false) {
        self.role = role; self.label = label; self.placeholder = placeholder; self.valuePreview = valuePreview; self.secure = secure
    }
}

public struct AppIdentity: Codable, Sendable, Equatable {
    public var name: String
    public var bundleId: String
    public var pid: Int32
    public init(name: String, bundleId: String, pid: Int32) { self.name = name; self.bundleId = bundleId; self.pid = pid }
}

/// One enabled command in the front app's menu bar, as a target for `menu_item`.
public struct MenuItem: Codable, Sendable, Equatable {
    public var id: String        // "m01"...
    public var path: String      // "File › Save"
    public init(id: String, path: String) { self.id = id; self.path = path }
}

public struct Observation: Codable, Sendable, Equatable {
    public var snapshotId: String
    public var takenAt: TimeInterval
    public var app: AppIdentity
    public var focusedField: FocusedField?
    public var elements: [Element]     // <= 100
    /// Labelled pressables outside the visible area (plan section 5, off-screen option).
    public var offscreen: [Element]
    /// The front tab's host name in a browser ("en.wikipedia.org"), never the path, query, or
    /// title (plan section 5 privacy rule, host added 2026-09-20 for goal mode).
    public var pageHost: String?
    /// The front app's enabled menu-bar commands (no Window or Help menu, no recent files).
    public var menus: [MenuItem] = []
    public var truncated: Bool
    public var tookMs: Double

    public init(snapshotId: String, takenAt: TimeInterval, app: AppIdentity, focusedField: FocusedField?,
                elements: [Element], offscreen: [Element] = [], pageHost: String? = nil, menus: [MenuItem] = [], truncated: Bool, tookMs: Double) {
        self.snapshotId = snapshotId; self.takenAt = takenAt; self.app = app; self.focusedField = focusedField
        self.elements = elements; self.offscreen = offscreen; self.pageHost = pageHost; self.menus = menus; self.truncated = truncated; self.tookMs = tookMs
    }

    enum CodingKeys: String, CodingKey { case snapshotId, takenAt, app, focusedField, elements, offscreen, pageHost, menus, truncated, tookMs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotId = try c.decode(String.self, forKey: .snapshotId)
        takenAt = try c.decode(TimeInterval.self, forKey: .takenAt)
        app = try c.decode(AppIdentity.self, forKey: .app)
        focusedField = try c.decodeIfPresent(FocusedField.self, forKey: .focusedField)
        elements = try c.decode([Element].self, forKey: .elements)
        offscreen = try c.decodeIfPresent([Element].self, forKey: .offscreen) ?? []
        pageHost = try c.decodeIfPresent(String.self, forKey: .pageHost)
        menus = try c.decodeIfPresent([MenuItem].self, forKey: .menus) ?? []
        truncated = try c.decode(Bool.self, forKey: .truncated)
        tookMs = try c.decode(Double.self, forKey: .tookMs)
    }
}

// MARK: - Actions and candidates

public enum ScrollDirection: String, Codable, Sendable { case up, down }
public enum ScrollAmount: String, Codable, Sendable { case little, page, end }

/// Where typed text goes relative to what the field already holds. `insert` adds at the caret;
/// the replace cases select the old text first so the keystrokes overwrite it ("change the
/// title to groceries" on a note already titled). Decided by Jev's `type_placement` head.
public enum TextPlacement: String, Codable, Sendable {
    case insert
    case replaceTitle = "replace_title"   // the field's first line: a note's title
    case replaceAll = "replace_all"       // the field's whole value
}

/// Every executable action with all its arguments. Built by code from Jev's option picks.
public enum Action: Codable, Sendable, Equatable {
    case openApp(bundleId: String, name: String)
    case newNote
    case typeText(text: String, placement: TextPlacement = .insert)
    case webSearch(url: String, query: String, site: String)
    case openSite(url: String, label: String)
    case takePhoto
    case clickElement(elementId: String)
    case pressEnter
    case pressEscape
    case scroll(direction: ScrollDirection, amount: ScrollAmount)
    case goBack
    /// Press a command in the front app's menu bar; `path` is "File › Save".
    case menuItem(id: String, path: String)

    /// Actions a spoken count may repeat: each run is bounded, verified on its own, and harmless
    /// to run again (a scroll, a Back, a key). Never typing, clicks, launches, or photos.
    public var repeatable: Bool {
        switch self {
        case .scroll, .goBack, .pressEnter, .pressEscape: true
        default: false
        }
    }

    /// Stable name used in logs, `recent_actions`, and the early-execution allowlist.
    public var kind: String {
        switch self {
        case .openApp: "open_app"
        case .newNote: "new_note"
        case .typeText: "type_text"
        case .webSearch: "web_search"
        case .openSite: "open_site"
        case .takePhoto: "take_photo"
        case .clickElement: "click_element"
        case .pressEnter: "press_enter"
        case .pressEscape: "press_escape"
        case .scroll(let d, _): d == .up ? "scroll_up" : "scroll_down"
        case .goBack: "go_back"
        case .menuItem: "menu_item"
        }
    }

    public var tier: RiskTier {
        switch self {
        case .typeText, .menuItem: .medium
        case .clickElement, .pressEnter: .gated
        default: .low
        }
    }

    /// Short human line for the overlay and `recent_actions`.
    public var summary: String {
        switch self {
        case .openApp(_, let name): "open_app \(name)"
        case .newNote: "new_note"
        case .typeText(let t, let p): p == .insert ? "type_text '\(t)'" : "type_text '\(t)' (\(p.rawValue))"
        case .webSearch(_, let q, let site): "web_search \(site) '\(q)'"
        case .openSite(_, let label): "open_site \(label)"
        case .takePhoto: "take_photo"
        case .clickElement(let id): "click_element \(id)"
        case .pressEnter: "press_enter"
        case .pressEscape: "press_escape"
        case .scroll(let d, let a): "scroll_\(d.rawValue) \(a.rawValue)"
        case .goBack: "go_back"
        case .menuItem(_, let path): "menu_item '\(path)'"
        }
    }
}

public enum RiskTier: String, Codable, Sendable { case low, medium, gated }

extension Action {
    /// A short human line for the overlay ("Open Notes", "Retitle “groceries”"); `summary`
    /// stays the stable machine form for logs and history.
    public var humanLabel: String {
        func q(_ t: String) -> String { "“\(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))”" }
        switch self {
        case .openApp(_, let name): return "Open \(name)"
        case .newNote: return "New note"
        case .typeText(let t, let p): return (p == .insert ? "Type " : p == .replaceTitle ? "Retitle " : "Replace with ") + q(t)
        case .webSearch(_, let query, let site): return "Search \(site) for \(q(query))"
        case .openSite(_, let label): return "Open \(label)"
        case .takePhoto: return "Take photo"
        case .clickElement(let id): return "Click \(id)"
        case .pressEnter: return "Return"
        case .pressEscape: return "Escape"
        case .scroll(let d, let a): return "Scroll \(d.rawValue)" + (a == .end ? " to the end" : a == .little ? " a bit" : "")
        case .goBack: return "Back"
        case .menuItem(_, let path): return path.components(separatedBy: " › ").last ?? path
        }
    }
}

extension Candidate {
    /// The overlay's line: a click names its element ("Click “Archive”"), not its id.
    public var humanLabel: String {
        var s = action.humanLabel
        if case .clickElement = action, let label, !label.isEmpty { s = "Click “\(label.prefix(24))”" }
        return repeats > 1 ? "\(s) ×\(repeats)" : s
    }

    /// How a spoken confirmation names it ("Say confirm to click Archive"). Only clicks and
    /// Return are gated, and both read as a person would say them.
    public var spokenLabel: String {
        switch action {
        case .clickElement: return "click " + (label.map { String($0.prefix(40)) } ?? "that")
        case .pressEnter: return "press Return"
        default: return action.humanLabel.lowercased()
        }
    }
}

public struct Candidate: Codable, Sendable, Equatable {
    public var id: String
    public var snapshotId: String
    public var action: Action
    public var targetElementId: String?
    /// Verbatim payload (typed text, search query) sliced from the raw transcript.
    public var payload: String?
    public var tier: RiskTier
    public var preconditions: [String]
    public var expectedPostcondition: String
    /// How many times the action runs ("scroll down three times"): a number code read from the
    /// transcript, applied only to actions that repeat safely (plan: code owns arithmetic).
    public var repeats: Int = 1
    /// The target element's label as the user sees it, for the overlay and spoken prompts only:
    /// never part of `summary`, so logs, replay, and the state sent to Jev are unchanged.
    public var label: String?

    public init(id: String, snapshotId: String, action: Action, targetElementId: String? = nil, payload: String? = nil,
                preconditions: [String] = [], expectedPostcondition: String, repeats: Int = 1, label: String? = nil) {
        self.id = id; self.snapshotId = snapshotId; self.action = action; self.targetElementId = targetElementId
        self.payload = payload; self.tier = action.tier; self.preconditions = preconditions
        self.expectedPostcondition = expectedPostcondition; self.repeats = repeats; self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, snapshotId, action, targetElementId, payload, tier, preconditions, expectedPostcondition, repeats, label }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        snapshotId = try c.decode(String.self, forKey: .snapshotId)
        action = try c.decode(Action.self, forKey: .action)
        targetElementId = try c.decodeIfPresent(String.self, forKey: .targetElementId)
        payload = try c.decodeIfPresent(String.self, forKey: .payload)
        tier = try c.decode(RiskTier.self, forKey: .tier)
        preconditions = try c.decode([String].self, forKey: .preconditions)
        expectedPostcondition = try c.decode(String.self, forKey: .expectedPostcondition)
        repeats = try c.decodeIfPresent(Int.self, forKey: .repeats) ?? 1
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    /// Summary with the repeat count when there is one.
    public var summary: String { repeats > 1 ? "\(action.summary) ×\(repeats)" : action.summary }
}

// MARK: - Decision

public struct GateReason: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var threshold: String
    public var pass: Bool
    public var note: String
    public init(name: String, value: String, threshold: String, pass: Bool, note: String) {
        self.name = name; self.value = value; self.threshold = threshold; self.pass = pass; self.note = note
    }
}

public enum DecisionOutcome: Codable, Sendable, Equatable {
    case act(candidateId: String)
    case wait(reason: String, retryInMs: Int?)
    case ignore(reason: String)
    case confirm(candidateId: String)
    case disambiguate(candidateIds: [String])

    public var name: String {
        switch self {
        case .act: "act"
        case .wait: "wait"
        case .ignore: "ignore"
        case .confirm: "confirm"
        case .disambiguate: "disambiguate"
        }
    }
}

public struct Decision: Codable, Sendable, Equatable {
    public var snapshotId: String
    public var candidateSetId: String
    public var utteranceId: String
    public var revision: Int
    public var intentEpoch: Int
    public var outcome: DecisionOutcome
    public var answers: [String: Answer]
    public var reasons: [GateReason]
    public var model: String
    public var latencyMs: Double
    public var usage: Usage
    public var requestId: String?

    public init(snapshotId: String, candidateSetId: String, utteranceId: String, revision: Int, intentEpoch: Int,
                outcome: DecisionOutcome, answers: [String: Answer], reasons: [GateReason], model: String,
                latencyMs: Double, usage: Usage, requestId: String?) {
        self.snapshotId = snapshotId; self.candidateSetId = candidateSetId; self.utteranceId = utteranceId
        self.revision = revision; self.intentEpoch = intentEpoch; self.outcome = outcome; self.answers = answers
        self.reasons = reasons; self.model = model; self.latencyMs = latencyMs; self.usage = usage; self.requestId = requestId
    }
}

// MARK: - Dispatch, ledger, verification

public enum DispatchStatus: String, Codable, Sendable { case acknowledged, failed, unknown }

/// Written before every dispatch. A lost acknowledgement leaves `unknown`; the next step is to
/// observe, never to retry a non-idempotent action.
public struct LedgerEntry: Codable, Sendable, Equatable {
    public var dispatchId: String
    public var utteranceId: String
    public var revision: Int
    public var snapshotId: String
    public var candidateId: String
    public var dispatchedAt: TimeInterval
    public var status: DispatchStatus
    public init(dispatchId: String, utteranceId: String, revision: Int, snapshotId: String, candidateId: String,
                dispatchedAt: TimeInterval, status: DispatchStatus) {
        self.dispatchId = dispatchId; self.utteranceId = utteranceId; self.revision = revision
        self.snapshotId = snapshotId; self.candidateId = candidateId; self.dispatchedAt = dispatchedAt; self.status = status
    }
}

public struct ActionResult: Codable, Sendable, Equatable {
    public var dispatchId: String
    public var status: DispatchStatus
    public var detail: String
    public var tookMs: Double
    public init(dispatchId: String, status: DispatchStatus, detail: String, tookMs: Double) {
        self.dispatchId = dispatchId; self.status = status; self.detail = detail; self.tookMs = tookMs
    }
}

public enum VerificationOutcome: String, Codable, Sendable { case verified, failed, unknown }

public enum VerificationEvidence: String, Codable, Sendable {
    case frontmostApp, fieldValue, url, noteCount, fileCount, snapshotDiff, none
}

public struct Verification: Codable, Sendable, Equatable {
    public var dispatchId: String
    public var expected: String
    public var observed: String
    public var outcome: VerificationOutcome
    public var evidence: VerificationEvidence
    public var nextStep: String
    public init(dispatchId: String, expected: String, observed: String, outcome: VerificationOutcome,
                evidence: VerificationEvidence, nextStep: String) {
        self.dispatchId = dispatchId; self.expected = expected; self.observed = observed
        self.outcome = outcome; self.evidence = evidence; self.nextStep = nextStep
    }
}
