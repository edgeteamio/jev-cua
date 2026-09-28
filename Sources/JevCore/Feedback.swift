import Foundation

/// What the overlay says about a decision (review 2026-09-28, item 1c). Decisions arrive every
/// ~110 ms while you talk, and showing each one ("deciding…", "not a command", "waiting for a
/// committed clause") read as flicker in the 2026-09-24 session. Only what the user can act on is
/// shown: a finished clause that is missing something ("open what?", "no field focused"), a
/// refusal, a cancellation.
public enum Feedback {
    /// Gates that fail while the words are still coming or the intent is still forming. A wait on
    /// one of these is the system working, not something to tell the user.
    static let timingGates: Set<String> = ["is_command", "intent", "early_allowlist", "intent_stable", "complete", "text_stable",
                                           "app_name_final", "payload_final"]

    /// The status line for a decision: "" clears it, nil leaves it as it is.
    public static func statusLine(for outcome: DecisionOutcome, reasons: [GateReason]) -> String? {
        switch outcome {
        case .act:
            return ""   // the action's chip carries it
        case .ignore(let reason):
            if reason == "cancelled" { return "cancelled" }
            if reason.hasPrefix("denied: ") { return "won't do that: " + reason.dropFirst("denied: ".count) }
            return nil   // chatter
        case .wait(let reason, _):
            // Past the timing gates (the clause committed, or a follow-up's phrase ended) and
            // still waiting: something is missing that only the user can supply.
            let committed = reasons.contains { ($0.name == "committed" || $0.name == "payload_final") && $0.pass }
            let timing = reasons.contains { !$0.pass && timingGates.contains($0.name) }
            return committed && !timing ? reason : nil
        case .confirm, .disambiguate:
            return nil   // they have their own prompts: the orange confirm line and the badges
        }
    }

    /// True when a decision says the words may be addressed to the computer, so the overlay opens
    /// for them. Chatter keeps the notch folded: in the 2026-09-24 session 195 of 253 decisions
    /// were conversation, all of it shown at the top of the screen.
    public static func engages(_ outcome: DecisionOutcome) -> Bool {
        if case .ignore(let reason) = outcome, reason == "not a command" { return false }
        return true
    }
}
