import Foundation

/// Everything a decision needs besides the answers. Built by the session (voice) or the lab
/// (typed); the policy and the state builder read it, never the other way around.
public struct DecisionContext: Sendable, Equatable, Codable {
    /// Raw unconsumed transcript (consumed prefix already removed). Spans index into this.
    public var rawTranscript: String
    public var isFinal: Bool
    public var frontmostApp: String
    public var frontmostBundleId: String?
    public var focusedField: FocusedField?
    public var pendingConfirmation: String?
    public var recentActions: [String]
    public var elements: [Element]
    public var offscreen: [Element] = []
    /// True when this text is what remained after a command in the same breath was consumed.
    public var afterConsumed: Bool = false
    /// The last executed action and how long ago it finished, for follow-up phrases
    /// ("open wikipedia" … "mark zuckerberg"). Nil when nothing ran recently.
    public var lastAction: Action? = nil
    public var lastActionAgeS: Double = 0
    /// Browser front tab host, when the front app is a browser.
    public var pageHost: String? = nil
    /// Menu-bar commands that the spoken words could name (already filtered, capped).
    public var menus: [MenuItem] = []
    public var installedApps: [String]
    public var runningApps: Set<String>

    public init(rawTranscript: String, isFinal: Bool, frontmostApp: String = "Finder", frontmostBundleId: String? = nil,
                focusedField: FocusedField? = nil, pendingConfirmation: String? = nil, recentActions: [String] = [],
                elements: [Element] = [], installedApps: [String] = [], runningApps: Set<String> = []) {
        self.rawTranscript = rawTranscript; self.isFinal = isFinal; self.frontmostApp = frontmostApp
        self.frontmostBundleId = frontmostBundleId; self.focusedField = focusedField
        self.pendingConfirmation = pendingConfirmation; self.recentActions = recentActions
        self.elements = elements; self.installedApps = installedApps; self.runningApps = runningApps
    }

    public var normalizedTranscript: String { Transcript.normalize(rawTranscript) }
}

/// The JSON `state` sent to Jev (plan section 6). Small on purpose; never includes window
/// titles, clipboard, file paths, element tokens, or the key.
public enum StateBuilder {
    public static func state(for ctx: DecisionContext) -> JSONValue {
        var s: [String: JSONValue] = [
            "transcript": .string(ctx.normalizedTranscript),
            "transcript_is_final": .bool(ctx.isFinal),
            "frontmost_app": .string(ctx.frontmostApp),
            "focused_field": ctx.focusedField.map { f in
                var d: [String: JSONValue] = ["role": .string(f.role), "secure": .bool(f.secure)]
                if let l = f.label { d["label"] = .string(l) }
                if let p = f.placeholder { d["placeholder"] = .string(p) }
                if let v = f.valuePreview { d["value_preview"] = .string(v) }
                return .object(d)
            } ?? .null,
            "pending_confirmation": ctx.pendingConfirmation.map(JSONValue.string) ?? .null,
            "recent_actions": .array(ctx.recentActions.suffix(3).map(JSONValue.string)),
            "page_host": ctx.pageHost.map(JSONValue.string) ?? .null,
            "last_action": ctx.lastAction.map { .object(["action": .string($0.summary), "seconds_ago": .number((ctx.lastActionAgeS * 10).rounded() / 10)]) } ?? .null,
            // Compact strings, not objects: "e01 button 'Take Photo' (bottom-center)". Each element
            // is also an option in a target head, so this is the cheap copy (plan section 6).
            "elements": .array({ let mates = Questions.rowMates(Array(ctx.elements.prefix(Config.maxElementsInState)))
                                 return ctx.elements.prefix(Config.maxElementsInState).map { e in .string("\(e.id) \(Questions.describe(e, mates: mates[e.id]))") } }()),
        ]
        if !ctx.menus.isEmpty { s["menus"] = .array(ctx.menus.map { .string("\($0.id) \($0.path)") }) }
        return .object(s)
    }
}
