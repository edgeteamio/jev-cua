import Foundation
import os
@testable import JevCore

/// Keyword-driven stand-in for Jev. Deterministic and shaped like real answers (probability
/// keys equal the option set, argmax is the choice), so the session's validation path runs.
final class FakeJev: JevDeciding, @unchecked Sendable {
    var delayMs: Int = 0
    let calls = OSAllocatedUnfairLock(initialState: [String]())

    init(delayMs: Int = 0) { self.delayMs = delayMs }

    func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse {
        let t = state["transcript"]?.stringValue ?? ""
        calls.withLock { $0.append(t) }
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }   // throws CancellationError when cancelled
        try Task.checkCancellation()
        let r = rules(t, pending: state["pending_confirmation"] != .null, field: state["focused_field"] != .null)
        var answers: [String: Answer] = [:]
        for (id, q) in questions {
            switch (id, q) {
            case ("intent", .choice(let c)): answers[id] = Self.choice(c, pick: r.intent, conf: r.conf)
            case ("app", .choice(let c)): answers[id] = Self.choice(c, pick: r.app, conf: 0.95)
            case ("site", .choice(let c)): answers[id] = Self.choice(c, pick: r.site, conf: 0.95)
            case ("complete", .noul): answers[id] = .noul(r.complete)
            case ("is_command", .noul): answers[id] = .noul(r.isCommand)
            case ("destructive", .noul): answers[id] = .noul(r.destructive)
            case ("scroll_amount", .score(let s)):
                let level = (t.contains("a bit") || t.contains("a little") || t.contains("slightly")) ? 0 : (t.contains("bottom") || t.contains("top") || t.contains("all the way") || t.contains("end")) ? 2 : 1
                answers[id] = .score(ScoreAnswer(score: Double(level), probabilities: Dictionary(uniqueKeysWithValues: (0..<s.criteria.count).map { (String($0), $0 == level ? 1.0 : 0.0) }), confidence: 0.9))
            case ("text_span", .choice(let c)): answers[id] = Self.choice(c, pick: r.span.flatMap { c.criteria[$0] != nil ? $0 : nil } ?? Questions.spanNone, conf: 0.9)
            case ("url_span", .choice(let c)): answers[id] = Self.choice(c, pick: r.url.flatMap { c.criteria[$0] != nil ? $0 : nil } ?? Questions.spanNone, conf: 0.9)
            case ("click_target", .choice(let c)):
                // Score options by label words present in the transcript; ties split the mass.
                let words = Set(t.split(separator: " ").map(String.init))
                var scores: [String: Int] = [:]
                for (id, desc) in c.criteria where id != Questions.targetNone {
                    let label = desc.stringValue?.lowercased() ?? ""
                    scores[id] = words.filter { $0.count > 2 && label.contains($0) }.count
                }
                let best = scores.values.max() ?? 0
                let winners = scores.filter { $0.value == best && best > 0 }.keys.sorted()
                var probs: [String: Double] = [:]
                let rest = winners.isEmpty ? 0.0 : 0.1 / Double(max(1, c.criteria.count - winners.count))
                // Ties split the mass; the first winner gets a hair more so the argmax is well defined.
                for k in c.criteria.keys { probs[k] = winners.contains(k) ? 0.9 / Double(winners.count) + (k == winners.first ? 0.01 : -0.01 / Double(max(1, winners.count - 1))) : rest }
                if winners.isEmpty { probs = Dictionary(uniqueKeysWithValues: c.criteria.keys.map { ($0, $0 == Questions.targetNone ? 0.9 : 0.1 / Double(c.criteria.count - 1)) }) }
                let pick = winners.first ?? Questions.targetNone
                let conf = winners.count == 1 ? 0.9 : (winners.isEmpty ? 0.9 : 0.3)
                answers[id] = .choice(ChoiceAnswer(choice: pick, probabilities: probs, confidence: conf))
            case ("type_target", .choice(let c)):
                answers[id] = Self.choice(c, pick: Questions.targetFocused, conf: 0.9)
            case ("followup", .choice(let c)):
                // A short verb-less phrase after an action supplies its text; chatter is unrelated.
                let pick = r.intent != "none" ? Questions.followupNewCommand
                    : (r.isCommand < 0.3 || t.split(separator: " ").count > 6) ? Questions.followupUnrelated : Questions.followupSuppliesText
                answers[id] = Self.choice(c, pick: pick, conf: 0.9)
            case ("command_span", .choice(let c)):
                let raw = t   // the normalized transcript equals the raw one in these fixtures (lowercase, no punctuation)
                let words = raw.split(separator: " ").map(String.init)
                let end = r.commandWords ?? words.count
                let pick = words.prefix(end).joined(separator: " ")
                answers[id] = Self.choice(c, pick: c.criteria[pick] != nil ? pick : Questions.commandSpanNone, conf: r.intent == "none" ? 0.3 : 0.9)
            default: break
            }
        }
        return JevResponse(model: "fake", answers: answers, usage: Usage(inputTokens: 100, outputTokens: 1), latencyMs: 1, requestId: nil)
    }

    static func choice(_ q: ChoiceQuestion, pick: String, conf: Double) -> Answer {
        let keys = Array(q.criteria.keys)
        let p = keys.contains(pick) ? pick : (keys.contains("none") ? "none" : keys.contains("not_stated") ? "not_stated" : keys[0])
        var probs: [String: Double] = [:]
        let rest = keys.count > 1 ? 0.1 / Double(keys.count - 1) : 0
        for k in keys { probs[k] = k == p ? (keys.count > 1 ? 0.9 : 1.0) : rest }
        return .choice(ChoiceAnswer(choice: p, probabilities: probs, confidence: conf))
    }

    struct Rule { var intent = "none"; var conf = 0.95; var complete = 0.1; var isCommand = 0.9; var destructive = 0.05
                  var app = "not_stated"; var site = "not_stated"; var span: String? = nil; var url: String? = nil
                  /// Word count of the command inside the (connector-stripped) transcript, for command_span.
                  var commandWords: Int? = nil }

    func rules(_ input: String, pending: Bool, field: Bool) -> Rule {
        var r = core(input, pending: pending, field: field)
        // command_span: the first command ends at a known phrase boundary.
        let words = input.split(separator: " ").map(String.init)
        let ends = ["notes app", "notes", "chrome", "safari", "photo booth", "finder", "wikipedia", "github", "youtube", "hacker news",
                    "x dot com", "new note", "picture of me", "a photo", "scroll down", "scroll up", "go back", "press escape", "press enter"]
        var best: Int? = nil
        for e in ends {
            let ew = e.split(separator: " ").map(String.init)
            guard words.count >= ew.count else { continue }
            if let i = (0...(words.count - ew.count)).first(where: { Array(words[$0..<$0 + ew.count]) == ew }) {
                best = min(best ?? .max, i + ew.count)
            }
        }
        if let best, r.intent != "none" { r.commandWords = best } else if r.intent == "web_search" || r.intent == "type_text" { r.commandWords = words.count }
        return r
    }

    func core(_ input: String, pending: Bool, field: Bool) -> Rule {
        var r = Rule()
        var t = input
        for c in ["all right ", "alright ", "okay ", "and then ", "then ", "and ", "now "] where t.hasPrefix(c) { t = String(t.dropFirst(c.count)) }
        let words = t.split(separator: " ").map(String.init)
        func after(_ trigger: String) -> String? { t.hasPrefix(trigger + " ") ? String(t.dropFirst(trigger.count + 1)) : nil }
        if t.hasPrefix("don't") || t.hasPrefix("i think") || t.hasPrefix("the weather") || t.hasPrefix("my title says") || t.hasPrefix("he said") || t == "um" {
            r.isCommand = 0.05; r.intent = "none"; return r
        }
        if ["stop", "cancel", "never mind"].contains(t) { r.intent = "cancel"; r.complete = 0.95; return r }
        if ["confirm", "yes", "yes do it", "go ahead"].contains(t) { r.intent = "confirm"; r.complete = 0.9; return r }
        let apps: [(String, String)] = [("notes", "notes"), ("chrome", "chrome"), ("safari", "safari"), ("photo booth", "photo_booth"), ("finder", "finder")]
        let sites: [(String, String)] = [("wikipedia", "wikipedia"), ("github", "github"), ("youtube", "youtube"), ("hacker news", "hacker_news")]
        if t.hasPrefix("open") || t.hasPrefix("launch") || t.hasPrefix("switch to") || t.hasPrefix("go to") || t.hasPrefix("take me to") {
            if let u = ["x dot com", "x dotcom", "x.com"].first(where: { t.contains($0) }) { r.intent = "open_site"; r.site = "x_twitter"; r.url = u; r.complete = 0.9; return r }
            if let a = apps.first(where: { t.contains($0.0) }) {
                r.intent = "open_app"; r.app = a.1; r.complete = t.hasSuffix(a.0) || t.contains(a.0 + " app") ? 0.9 : 0.75; r.conf = 0.98; return r
            }
            if let s = sites.first(where: { t.contains($0.0) }) { r.intent = "open_site"; r.site = s.1; r.complete = 0.9; r.conf = 0.98; return r }
            if t.contains("new note") { r.intent = "new_note"; r.complete = 0.9; return r }
            r.intent = "none"; r.conf = 0.9; r.complete = 0.05; return r
        }
        if t.contains("new note") { r.intent = "new_note"; r.complete = t.hasSuffix("note") ? 0.9 : 0.3; return r }
        if let q = after("google search") ?? after("search for") ?? after("look up") {
            r.intent = "web_search"; r.site = t.hasPrefix("google") ? "google" : "not_stated"; r.span = q; r.complete = words.count >= 4 ? 0.85 : 0.4; return r
        }
        if t.hasPrefix("google search") || t.hasPrefix("search for") { r.intent = "web_search"; r.complete = 0.2; return r }
        if t.hasPrefix("take a picture") || t.hasPrefix("take a photo") { r.intent = "take_photo"; r.complete = 0.9; return r }
        if let s = after("make the title say") ?? after("type") { r.intent = "type_text"; r.span = s; r.complete = 0.85; return r }
        if t.hasPrefix("make the title") || t == "type" { r.intent = "type_text"; r.complete = 0.2; return r }
        if t.hasPrefix("click") { r.intent = "click_element"; r.complete = words.count >= 3 ? 0.8 : 0.3; return r }
        if t.hasPrefix("press enter") || t == "submit" { r.intent = "press_enter"; r.complete = 0.9; r.destructive = t.contains("send") ? 0.9 : 0.05; return r }
        if t.hasPrefix("send") { r.intent = "press_enter"; r.complete = 0.9; r.destructive = 0.9; return r }
        if t.hasPrefix("press escape") || t.hasPrefix("dismiss") { r.intent = "press_escape"; r.complete = 0.9; return r }
        if t.hasPrefix("scroll down") { r.intent = "scroll_down"; r.complete = 0.9; return r }
        if t.hasPrefix("scroll up") { r.intent = "scroll_up"; r.complete = 0.9; return r }
        if t.hasPrefix("go back") { r.intent = "go_back"; r.complete = 0.9; return r }
        if t.hasPrefix("scroll") { r.intent = "scroll_down"; r.conf = 0.5; r.complete = 0.3; return r }
        r.intent = "none"; r.conf = 0.9; r.complete = 0.05
        return r
    }
}

final class FakePerception: Perceiving, @unchecked Sendable {
    let state = OSAllocatedUnfairLock(initialState: (snapshot: 1, field: FocusedField?.none, app: AppIdentity(name: "Finder", bundleId: "com.apple.finder", pid: 1), observed: 0, elements: [Element]()))
    init(field: FocusedField? = nil, app: AppIdentity? = nil, elements: [Element] = []) {
        state.withLock { if let app { $0.app = app }; $0.field = field; $0.elements = elements }
    }
    func observe() async -> Observation {
        state.withLock {
            $0.observed += 1
            return Observation(snapshotId: "s\($0.snapshot)", takenAt: 0, app: $0.app, focusedField: $0.field, elements: $0.elements, truncated: false, tookMs: 0)
        }
    }
    func invalidate() async { state.withLock { $0.snapshot += 1 } }
    func setApp(_ app: AppIdentity) { state.withLock { $0.app = app } }
    var currentSnapshotId: String { state.withLock { "s\($0.snapshot)" } }
}

final class FakeExecutor: Executing, @unchecked Sendable {
    struct Record: Equatable { var summary: String; var snapshotId: String; var candidateId: String }
    let records = OSAllocatedUnfairLock(initialState: [Record]())
    let perception: FakePerception
    var executeDelayMs = 0
    /// Force every verification to this outcome (tests for unknown / failed handling).
    var verificationOverride: VerificationOutcome?
    init(perception: FakePerception) { self.perception = perception }

    func execute(_ candidate: Candidate, observation: Observation) async -> ExecutionOutcome {
        // A candidate must be executed against the observation it was built from.
        let stale = candidate.snapshotId != observation.snapshotId || observation.snapshotId != perception.currentSnapshotId
        records.withLock { $0.append(Record(summary: candidate.action.summary, snapshotId: candidate.snapshotId, candidateId: candidate.id)) }
        if executeDelayMs > 0 { try? await Task.sleep(for: .milliseconds(executeDelayMs)) }
        if case .openApp(_, let name) = candidate.action { perception.setApp(AppIdentity(name: name, bundleId: "fake.\(name)", pid: 2)) }
        let status: DispatchStatus = stale ? .failed : .acknowledged
        let outcome: VerificationOutcome = verificationOverride ?? (stale ? .failed : .verified)
        return ExecutionOutcome(result: ActionResult(dispatchId: "", status: status, detail: stale ? "stale snapshot" : "ok", tookMs: 1),
                                verification: Verification(dispatchId: "", expected: candidate.expectedPostcondition, observed: stale ? "stale" : "ok",
                                                           outcome: outcome, evidence: .none, nextStep: ""))
    }
    var summaries: [String] { records.withLock { $0.map(\.summary) } }
}

/// Manual clock: time only moves when the test says so; sleeps are instant.
final class ManualClock: Clock, @unchecked Sendable {
    let t = OSAllocatedUnfairLock(initialState: 0.0)
    func now() -> TimeInterval { t.withLock { $0 } }
    func advance(ms: Double) { t.withLock { $0 += ms / 1000 } }
    func sleep(ms: Int) async { await Task.yield() }
}
