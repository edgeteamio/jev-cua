import Foundation

/// Input to one policy evaluation. The session or lab fills it; the policy is a pure function.
public struct PolicyInput: Sendable {
    public var answers: [String: Answer]
    public var spans: SpanSet
    public var context: DecisionContext
    /// Milliseconds since the transcript last changed with the microphone quiet (plan 9.5).
    public var silentMs: Double
    /// Milliseconds since the transcript last changed, mic ignored (word stability).
    public var transcriptStableMs: Double = 0
    /// True when the intent option equals the previous revision's intent (plan 9.2).
    public var intentStable: Bool
    public var pending: Candidate?
    public var snapshotId: String

    public init(answers: [String: Answer], spans: SpanSet, context: DecisionContext, silentMs: Double = 0,
                intentStable: Bool = false, pending: Candidate? = nil, snapshotId: String = "none", transcriptStableMs: Double? = nil) {
        self.answers = answers; self.spans = spans; self.context = context; self.silentMs = silentMs
        self.intentStable = intentStable; self.pending = pending; self.snapshotId = snapshotId
        self.transcriptStableMs = transcriptStableMs ?? silentMs
    }
}

public struct PolicyResult: Sendable, Equatable {
    public var outcome: DecisionOutcome
    public var candidate: Candidate?
    public var reasons: [GateReason]
    public var summary: String
    public var intent: String
    public var intentConfidence: Double
    /// The prefix of the unconsumed transcript that holds the executed command, when Jev was
    /// confident about it; the session consumes this instead of the whole text.
    public var commandSpan: String?
}

/// The gate order from plan 9.4. Every gate appends a reason so the overlay and the run log
/// can show why the policy acted or waited. Ported in shape from moritzkremb/jev-voice-browser
/// src/policy.js.
public enum Policy {
    public static func evaluate(_ input: PolicyInput) -> PolicyResult {
        var reasons: [GateReason] = []
        let a = input.answers
        let ctx = input.context
        let intentAnswer = a["intent"]?.choice
        var intent = intentAnswer?.choice ?? "none"
        var conf = intentAnswer?.confidence ?? 0
        // A visible control and a menu command that name the same thing ("close the window": the
        // window's close button and File › Close) split Jev between click_element and menu_item.
        // They are one wish: when those are the top two, their mass is the intent's, and a control
        // picked with confidence wins, since a visible control needs no menu. With no confident
        // control and menus on offer, the menu branch keeps it. (Targets lab, 2026-09-22.)
        if let ia = intentAnswer, Set(ia.ranked().prefix(2).map(\.id)) == ["click_element", "menu_item"] {
            let mass = min(1, (ia.probabilities["click_element"] ?? 0) + (ia.probabilities["menu_item"] ?? 0))
            let clickOk = a["click_target"]?.choice.map { $0.choice != Questions.targetNone && $0.confidence >= Config.T.targetConfidence } ?? false
            intent = (clickOk || ctx.menus.isEmpty) ? "click_element" : "menu_item"
            conf = max(conf, mass)
            reasons.append(GateReason(name: "intent_merge", value: "click_element+menu_item (\(String(format: "%.2f", mass)))", threshold: "-", pass: true,
                                      note: intent == "click_element" ? "one wish; the visible control wins" : "one wish; no confident control, the menu command"))
        }

        func check(_ name: String, _ value: String, _ threshold: String, _ pass: Bool, _ note: String) -> Bool {
            reasons.append(GateReason(name: name, value: value, threshold: threshold, pass: pass, note: note))
            return pass
        }
        let commandSpan: String? = {
            guard let c = a["command_span"]?.choice, c.choice != Questions.commandSpanNone else { return nil }
            let prefixes = Questions.commandPrefixes(ctx.rawTranscript)
            if c.confidence >= Config.T.commandSpanConfidence, prefixes.contains(c.choice) { return c.choice }
            // Unsure between two prefixes: a joiner right after the shorter one marks the clause
            // boundary ("open the notes app | and create a new note").
            let top = c.ranked(excluding: [Questions.commandSpanNone]).prefix(2).filter { $0.p >= 0.2 && prefixes.contains($0.id) }
            guard top.count == 2 else { return nil }
            let shorter = top[0].id.count <= top[1].id.count ? top[0].id : top[1].id
            let rest = Transcript.stripConsumed(raw: ctx.rawTranscript, consumedPrefix: shorter) ?? ""
            let joiners = ["and then ", "and ", "then ", "after that ", "next "]
            if joiners.contains(where: { rest.lowercased().hasPrefix($0) }) { return shorter }
            return nil
        }()
        func result(_ outcome: DecisionOutcome, _ summary: String, candidate: Candidate? = nil) -> PolicyResult {
            PolicyResult(outcome: outcome, candidate: candidate, reasons: reasons, summary: summary, intent: intent, intentConfidence: conf, commandSpan: commandSpan)
        }
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

        let committed = ctx.isFinal || input.silentMs >= Double(Config.silenceCompleteMs)

        // 1. Pending confirmation.
        if let pending = input.pending {
            if intent == "confirm", conf >= Config.T.intentConfidence {
                _ = check("intent", "confirm (\(fmt(conf)))", fmt(Config.T.intentConfidence), true, "pending action confirmed")
                return result(.act(candidateId: pending.id), "confirmed: \(pending.action.summary)", candidate: pending)
            }
            if intent == "cancel", conf >= Config.T.intentConfidence {
                _ = check("intent", "cancel (\(fmt(conf)))", fmt(Config.T.intentConfidence), true, "pending action cancelled")
                return result(.ignore(reason: "cancelled"), "cancelled pending action")
            }
        }

        // 1b. A follow-up phrase: no verb of its own, but it supplies what the last action needs
        // ("open wikipedia" … "mark zuckerberg" searches Wikipedia; "open the notes app" … "Mark
        // Zuckerberg" types into the note). Jev judges the relation; code maps it onto the action.
        // Only on a committed phrase, and never over a confident command of its own.
        let followup = a["followup"]?.choice
        let intentOk = intent != "none" && conf >= Config.T.intentConfidence
        let isFollowup = followup.map { [Questions.followupSuppliesText, Questions.followupRepeatsAction].contains($0.choice) } ?? false
        if let f = followup, isFollowup, !intentOk || (a["is_command"]?.noul ?? 0) < Config.T.isCommand {
            let repeats = f.choice == Questions.followupRepeatsAction
            let ok = f.confidence >= Config.T.followupConfidence
            _ = check("followup", "\(f.choice) (\(fmt(f.confidence)))", fmt(Config.T.followupConfidence), ok, repeats ? "asks to run the last action again" : "phrase supplies the last action's text")
            if ok {
                let payloadOk = ctx.isFinal || input.silentMs >= Double(Config.payloadSilenceMs)
                _ = check("payload_final", ctx.isFinal ? "final" : "silent \(Int(input.silentMs)) ms", "final or \(Config.payloadSilenceMs) ms", payloadOk, repeats ? "the request must be finished" : "the phrase must be finished before it is copied")
                if !payloadOk { return result(.wait(reason: "waiting for the end of the phrase", retryInMs: max(50, Config.payloadSilenceMs - Int(input.silentMs))), "waiting for the payload") }
                let built = repeats ? CandidateBuilder.buildRepeat(input: input, reasons: &reasons) : CandidateBuilder.buildFollowup(input: input, reasons: &reasons)
                if let candidate = built.candidate {
                    if let denial = CandidateBuilder.denial(for: candidate, context: ctx) {
                        _ = check("deny_list", denial, "-", false, "denied by policy")
                        return result(.ignore(reason: "denied: \(denial)"), "denied: \(denial)")
                    }
                    return result(.act(candidateId: candidate.id), candidate.summary, candidate: candidate)
                }
                return result(.wait(reason: built.reason ?? "no way to apply the phrase", retryInMs: nil), built.reason ?? "no way to apply the phrase")
            }
        }

        // 2. Addressed to the computer? A remainder after a consumed command is held to a higher
        // bar: a leftover noun phrase ("Mark Zuckerberg" after "open Wikipedia" fired early) must
        // not become a search of its own.
        let isCmd = a["is_command"]?.noul ?? 0
        let isCmdThreshold = ctx.afterConsumed ? Config.T.isCommandAfterConsumed : Config.T.isCommand
        if !check("is_command", fmt(isCmd), fmt(isCmdThreshold), isCmd >= isCmdThreshold, ctx.afterConsumed ? "remainder is a command of its own" : "user is addressing the computer") {
            return result(.ignore(reason: "not a command"), "not a command")
        }

        // 3. Confident intent?
        _ = check("intent", "\(intent) (\(fmt(conf)))", fmt(Config.T.intentConfidence), intentOk, "confident, non-none intent")
        if !intentOk {
            return result(.wait(reason: intent == "none" ? "no recognizable command yet" : "intent not confident yet", retryInMs: nil),
                          intent == "none" ? "nothing yet" : "intent not confident")
        }

        // 4. Early execution is restricted to the allowlist and requires a stable intent.
        if !committed {
            let allowed = Config.earlyExecutionKinds.contains(intent)
            _ = check("early_allowlist", intent, "allowlisted", allowed, allowed ? "may fire on a partial" : "waits for a committed clause")
            if !allowed {
                return result(.wait(reason: "waiting for the end of the command", retryInMs: Config.silenceCompleteMs), "waiting for a committed clause")
            }
            let stableEnough = input.intentStable || conf >= Config.T.earlyHighConfidence
            _ = check("intent_stable", input.intentStable ? "stable" : "changed (\(fmt(conf)))",
                      "2 revisions or conf >= \(fmt(Config.T.earlyHighConfidence))", stableEnough,
                      input.intentStable ? "intent held across consecutive revisions" : "single revision, high confidence")
            if !stableEnough {
                return result(.wait(reason: "intent not yet stable", retryInMs: Config.throttleMs), "intent changed this revision")
            }
            // 5. Complete?
            let complete = a["complete"]?.noul ?? 0
            if !check("complete", fmt(complete), fmt(Config.T.complete), complete >= Config.T.complete, "verb and required object present") {
                return result(.wait(reason: "waiting for the rest of the command", retryInMs: Config.throttleMs), "command not complete")
            }
            // 5b. A site that can be searched ("open wikipedia | mark zuckerberg"): the next words
            // may be a query, so the home page waits until the words have held still.
            let spokenDomain = a["url_span"]?.choice.map { $0.choice != Questions.spanNone } ?? false
            if intent == "open_site", !spokenDomain, let site = a["site"]?.choice?.choice, Config.site(option: site)?.search != nil {
                let stable = input.transcriptStableMs >= Double(Config.T.earlyScrollStableMs)
                _ = check("text_stable", "\(Int(input.transcriptStableMs)) ms", ">= \(Config.T.earlyScrollStableMs) ms", stable, "no query following the site name")
                if !stable { return result(.wait(reason: "a query may follow the site name", retryInMs: Config.T.earlyScrollStableMs), "site name not settled") }
            }
            // 5c. Scroll direction and amount ride on short words the recognizer revises ("scroll
            // down" became "scroll up"; "scroll down" fired before "a little"): the transcript
            // must have held still for a moment.
            if intent == "scroll_down" || intent == "scroll_up" {
                let stable = input.transcriptStableMs >= Double(Config.T.earlyScrollStableMs)
                _ = check("text_stable", "\(Int(input.transcriptStableMs)) ms", ">= \(Config.T.earlyScrollStableMs) ms", stable, "direction and amount words settled")
                if !stable { return result(.wait(reason: "waiting for the words to settle", retryInMs: Config.T.earlyScrollStableMs), "scroll words not settled") }
            }
            // 5a. An app name spoken so far must not be extendable into another app's name:
            // the last word could grow ("launch photo" -> "launch photos"), or the words so far
            // are the start of a longer name ("launch photo" -> "launch photo booth"; lab
            // 2026-09-20, when `complete` alone stopped separating them). Code knows the
            // names. The generic words "app" / "application" are not a name and are skipped.
            let nameWords = ctx.normalizedTranscript.split(separator: " ").map(String.init).filter { !["app", "application", "the", "up"].contains($0) }
            if intent == "open_app", let chosen = a["app"]?.choice?.choice, let last = nameWords.last, last.count >= 2 {
                let chosenName = Config.app(option: chosen)?.name ?? ctx.installedApps.first { Questions.optionId(forApp: $0) == chosen } ?? ""
                let others = (Config.apps.map(\.name) + ctx.installedApps + Array(ctx.runningApps)).filter { $0.caseInsensitiveCompare(chosenName) != .orderedSame }
                let extendable = others.first { name in
                    let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                    if words.contains(where: { $0.count > last.count && $0.hasPrefix(last) }) { return true }
                    return (1..<max(words.count, 1)).contains { k in k <= nameWords.count && Array(nameWords.suffix(k)) == Array(words.prefix(k)) }
                }
                if !check("app_name_final", last, "not a prefix of another app", extendable == nil, extendable.map { "could still become \($0)" } ?? "no other app starts this way") {
                    return result(.wait(reason: "app name may continue", retryInMs: Config.throttleMs), "waiting: '\(last)' could become \(extendable!)")
                }
            }
        } else {
            _ = check("committed", ctx.isFinal ? "final" : "silent \(Int(input.silentMs)) ms", "final or \(Config.silenceCompleteMs) ms", true, "clause committed")
        }

        // 5b. Free-text payloads wait for a committed clause (or payload silence).
        let usesSpokenDomain = intent == "open_site" && (a["url_span"]?.choice.map { $0.choice != Questions.spanNone } ?? false)
        let isPayload = (Config.payloadIntents.contains(intent) && intent != "open_site") || usesSpokenDomain
        if isPayload {
            let payloadOk = ctx.isFinal || input.silentMs >= Double(Config.payloadSilenceMs)
            _ = check("payload_final", ctx.isFinal ? "final" : "silent \(Int(input.silentMs)) ms", "final or \(Config.payloadSilenceMs) ms", payloadOk, "free text must be finished before it is copied")
            if !payloadOk {
                return result(.wait(reason: "waiting for the end of the phrase", retryInMs: max(50, Config.payloadSilenceMs - Int(input.silentMs))), "waiting for the payload")
            }
        }

        // 6. Build the concrete candidate in code.
        var built = CandidateBuilder.build(intent: intent, input: input, reasons: &reasons)
        // 6a. A spoken count repeats a repeatable action exactly; code reads the number.
        if var c = built.candidate, c.action.repeatable, let n = Spans.repetitions(in: ctx.rawTranscript) {
            c.repeats = n
            // "Three times" counts screens, not the nudges `scroll_amount` would give a bare "scroll down".
            if case .scroll(let d, .little) = c.action { c.action = .scroll(direction: d, amount: .page) }
            built.candidate = c
            _ = check("repeat", "\(n)×", "-", true, "spoken count, code repeats")
        }
        guard let candidate = built.candidate else {
            if built.disambiguate.count >= 2 {
                return result(.disambiguate(candidateIds: built.disambiguate), "which one? say a number (\(built.disambiguate.count) choices)")
            }
            return result(.wait(reason: built.reason ?? "missing argument", retryInMs: nil), built.reason ?? "missing argument")
        }

        // 8. Gated tier and destructive.
        if candidate.tier == .gated {
            let d = a["destructive"]?.noul ?? 0
            let safe = d < Config.T.destructive
            _ = check("destructive", fmt(d), fmt(Config.T.destructive), safe, safe ? "reversible action" : "needs spoken confirmation")
            if !safe { return result(.confirm(candidateId: candidate.id), "say confirm to \(candidate.action.summary)", candidate: candidate) }
        }

        // 9. Deny list re-check.
        if let denial = CandidateBuilder.denial(for: candidate, context: ctx) {
            _ = check("deny_list", denial, "-", false, "denied by policy")
            return result(.ignore(reason: "denied: \(denial)"), "denied: \(denial)")
        }

        return result(.act(candidateId: candidate.id), candidate.summary, candidate: candidate)
    }
}

/// Step 6 of the gate order: Jev picked options, code builds the executable action.
public enum CandidateBuilder {
    public struct Built: Sendable {
        public var candidate: Candidate?
        public var reason: String?
        /// Element ids to show as numbered badges when the target head could not pick one.
        public var disambiguate: [String] = []
    }

    public static func build(intent: String, input: PolicyInput, reasons: inout [GateReason]) -> Built {
        let a = input.answers
        let ctx = input.context
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
        func make(_ action: Action, payload: String? = nil, target: String? = nil, post: String) -> Built {
            Built(candidate: Candidate(id: Ident.make("c"), snapshotId: input.snapshotId, action: action, targetElementId: target,
                                       payload: payload, expectedPostcondition: post), reason: nil)
        }
        func wait(_ reason: String) -> Built { Built(candidate: nil, reason: reason) }

        /// Span pick with the plan's low-confidence rule (section 8).
        func pickSpan(lenient: Bool) -> (text: String, note: String)? {
            guard let ans = a["text_span"]?.choice else { return nil }
            if ans.choice == Questions.spanNone { return nil }
            guard input.spans.payload(text: ans.choice) != nil else { return nil }
            var text = ans.choice
            var note = "conf \(fmt(ans.confidence))"
            // A pick that still starts with a trigger ("google mark zuckerberg") when its remainder
            // is itself a candidate: the remainder is the payload; code knows the trigger words.
            let lower = Transcript.normalize(text)
            for trigger in Spans.triggers where lower.hasPrefix(trigger + " ") {
                let rest = String(text.dropFirst(text.count - (lower.count - trigger.count - 1))).trimmingCharacters(in: .whitespaces)
                if let c = input.spans.payload.first(where: { Transcript.normalize($0.text) == Transcript.normalize(rest) }) {
                    text = c.text; note += ", trigger '\(trigger)' stripped"
                }
                break
            }
            // A trigger the code knows ("jot down", "find me") produced the remainder as a candidate;
            // when Jev's pick is a strict tail of that remainder at modest confidence ("mom tomorrow"
            // for "jot down call mom tomorrow"), the remainder is the payload.
            if ans.confidence < 0.6 {
                let lower = Transcript.normalize(ctx.rawTranscript)
                for trigger in Spans.triggers where lower.contains(trigger + " ") {
                    guard let r = lower.range(of: trigger + " ") else { continue }
                    let remainder = String(lower[r.upperBound...])
                    // Only a one-word trim ("mom tomorrow" for "call mom tomorrow"); a short pick out
                    // of a long remainder ("Lovelace" from "first name Ada and last name Lovelace") stands.
                    if let c = input.spans.payload.first(where: { Transcript.normalize($0.text) == remainder }),
                       remainder != Transcript.normalize(text), remainder.hasSuffix(" " + Transcript.normalize(text)),
                       Transcript.wordCount(remainder) - Transcript.wordCount(text) <= 1 {
                        text = c.text; note = "trigger '\(trigger)' remainder over Jev's tail (\(fmt(ans.confidence)))"
                    }
                    break
                }
            }
            if ans.confidence < Config.T.spanConfidence {
                return lenient ? (text, "low confidence \(fmt(ans.confidence)), top candidate used") : nil
            }
            return (text, note)
        }

        /// A direct question is its own query ("what time is it in tokyo"): Jev's span head may
        /// answer none because nothing is "to be typed", but the search wants the whole question.
        func questionQuery() -> String? {
            let words = ctx.normalizedTranscript.split(separator: " ").map(String.init)
            guard words.count >= 3, let first = words.first,
                  ["who", "what", "when", "where", "why", "how", "is", "are", "does", "do", "can", "which", "whats", "what's"].contains(first) else { return nil }
            return ctx.rawTranscript.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
        }

        switch intent {
        case "open_app":
            guard let app = a["app"]?.choice, app.choice != Questions.appNotStated else {
                reasons.append(GateReason(name: "app", value: "not_stated", threshold: "named", pass: false, note: "open what?"))
                return wait("open what?")
            }
            if let entry = Config.app(option: app.choice) {
                reasons.append(GateReason(name: "app", value: "\(entry.name) (\(fmt(app.confidence)))", threshold: "-", pass: true, note: "catalog app"))
                return make(.openApp(bundleId: entry.bundleId, name: entry.name), post: "frontmost app is \(entry.bundleId)")
            }
            if app.choice.hasPrefix("app:"), let name = ctx.installedApps.first(where: { Questions.optionId(forApp: $0) == app.choice }) {
                reasons.append(GateReason(name: "app", value: "\(name) (\(fmt(app.confidence)))", threshold: "-", pass: true, note: "installed app"))
                return make(.openApp(bundleId: "", name: name), post: "frontmost app is \(name)")
            }
            return wait("unknown app option \(app.choice)")

        case "new_note":
            return make(.newNote, post: "note count increased by one")

        case "web_search":
            guard let pick = pickSpan(lenient: true) ?? questionQuery().map({ ($0, "whole question as the query") }) else {
                reasons.append(GateReason(name: "text_span", value: "none", threshold: fmt(Config.T.spanConfidence), pass: false, note: "no query text yet"))
                return wait("search for what?")
            }
            reasons.append(GateReason(name: "text_span", value: pick.text, threshold: fmt(Config.T.spanConfidence), pass: true, note: pick.note))
            let siteOpt = a["site"]?.choice?.choice ?? Questions.siteNotStated
            let site = Config.site(option: siteOpt).flatMap { $0.search != nil ? $0 : nil } ?? Config.site(option: Config.defaultSearchSite)!
            let cleaned = cleanQuery(pick.text, site: site)
            if cleaned.text != pick.text { reasons.append(GateReason(name: "query", value: cleaned.text, threshold: "-", pass: true, note: cleaned.note)) }
            let query = cleaned.text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cleaned.text
            let template = (cleaned.newest ? site.newestSearch : nil) ?? site.search!
            let url = template.replacingOccurrences(of: "%s", with: query)
            return make(.webSearch(url: url, query: cleaned.text, site: site.option), payload: cleaned.text, post: "active tab URL contains \(site.option) search for the query")

        case "open_site":
            if let u = a["url_span"]?.choice, u.choice != Questions.spanNone, input.spans.url(text: u.choice) != nil,
               let url = Spans.toHttpURL(u.choice) {
                reasons.append(GateReason(name: "url_span", value: u.choice, threshold: fmt(Config.T.spanConfidence), pass: true, note: "spoken domain"))
                return make(.openSite(url: url, label: u.choice), payload: u.choice, post: "active tab host matches")
            }
            if let s = a["site"]?.choice, let entry = Config.site(option: s.choice) {
                reasons.append(GateReason(name: "site", value: "\(entry.option) (\(fmt(s.confidence)))", threshold: "-", pass: true, note: "catalog site"))
                return make(.openSite(url: entry.home, label: entry.option), post: "active tab host matches \(entry.home)")
            }
            reasons.append(GateReason(name: "site", value: a["site"]?.choice?.choice ?? "-", threshold: "catalog site or spoken domain", pass: false, note: "no destination yet"))
            return wait("where to?")

        case "take_photo":
            return make(.takePhoto, post: "Photo Booth picture count increased by one")

        case "type_text":
            // Phase 4: a named field on screen wins over the focused one; the head is only asked
            // when editable elements exist, so its absence means "focused or nothing".
            var target: String? = nil
            if let t = a["type_target"]?.choice, t.choice != Questions.targetFocused, t.choice != Questions.targetNone,
               t.confidence >= Config.T.targetConfidence, let e = ctx.elements.first(where: { $0.id == t.choice && $0.editable && !$0.secure }) {
                reasons.append(GateReason(name: "type_target", value: "\(e.id) '\(e.text)' (\(fmt(t.confidence)))", threshold: fmt(Config.T.targetConfidence), pass: true, note: "named field"))
                target = e.id
            }
            let focusedOk = ctx.focusedField.map { !$0.secure && isEditable($0.role) } ?? false
            guard target != nil || focusedOk else {
                reasons.append(GateReason(name: "focused_field", value: ctx.focusedField?.role ?? "none", threshold: "editable, not secure", pass: false, note: "no field focused"))
                return wait("no field focused")
            }
            guard let pick = pickSpan(lenient: false) else {
                reasons.append(GateReason(name: "text_span", value: a["text_span"]?.choice?.choice ?? "none", threshold: fmt(Config.T.spanConfidence), pass: false, note: "type what?"))
                return wait("type what?")
            }
            reasons.append(GateReason(name: "text_span", value: pick.text, threshold: fmt(Config.T.spanConfidence), pass: true, note: pick.note))
            // Replace only on a confident head; otherwise insert, which the user can undo without
            // losing anything.
            var placement = TextPlacement.insert
            if let p = a["type_placement"]?.choice, let chosen = TextPlacement(rawValue: p.choice), chosen != .insert {
                let ok = p.confidence >= Config.T.placementConfidence
                reasons.append(GateReason(name: "type_placement", value: "\(chosen.rawValue) (\(fmt(p.confidence)))", threshold: fmt(Config.T.placementConfidence), pass: ok, note: ok ? "old text replaced" : "unsure: inserting"))
                if ok { placement = chosen }
            }
            let post = switch placement {
            case .insert: target == nil ? "focused field value contains the text" : "field \(target!) value contains the text"
            case .replaceTitle: "the field's first line is the text"
            case .replaceAll: "the field's value is the text"
            }
            return make(.typeText(text: pick.text, placement: placement), payload: pick.text, target: target, post: post)

        case "click_element":
            /// Off-screen pressables are consulted only when nothing visible matches.
            func offscreenPick() -> Built? {
                guard let o = a["offscreen_target"]?.choice, o.choice != Questions.targetNone, o.confidence >= Config.T.targetConfidence,
                      let e = ctx.offscreen.first(where: { $0.id == o.choice }) else { return nil }
                reasons.append(GateReason(name: "offscreen_target", value: "\(e.id) '\(e.text)' (\(fmt(o.confidence)))", threshold: fmt(Config.T.targetConfidence), pass: true, note: "labelled off-screen control"))
                return make(.clickElement(elementId: e.id), target: e.id, post: "'\(e.text)' pressed: focus, window, or value changed")
            }
            guard let t = a["click_target"]?.choice else {
                if let off = offscreenPick() { return off }
                reasons.append(GateReason(name: "click_target", value: "no elements", threshold: "-", pass: false, note: "no clickable element on this screen"))
                return wait("no clickable element on this screen")
            }
            let ranked = t.ranked(excluding: [Questions.targetNone]).filter { id in ctx.elements.contains { $0.id == id.id } }
            guard t.choice != Questions.targetNone, let top = ranked.first else {
                if let off = offscreenPick() { return off }
                reasons.append(GateReason(name: "click_target", value: "none (\(fmt(t.confidence)))", threshold: "an element id", pass: false, note: "no element matches"))
                return wait("which element?")
            }
            let confident = t.confidence >= Config.T.targetConfidence && top.p >= Config.T.targetTopProb
            if confident {
                reasons.append(GateReason(name: "click_target", value: "\(top.id) (\(fmt(t.confidence)), p \(fmt(top.p)))",
                                          threshold: "conf >= \(fmt(Config.T.targetConfidence)), p >= \(fmt(Config.T.targetTopProb))", pass: true, note: "target chosen"))
                let label = ctx.elements.first { $0.id == top.id }?.text ?? top.id
                return make(.clickElement(elementId: top.id), target: top.id, post: "'\(label)' pressed: focus, window, or value changed")
            }
            let contenders = ranked.prefix(4).filter { $0.p >= Config.T.disambiguateMinProb }.map(\.id)
            reasons.append(GateReason(name: "click_target", value: "\(top.id) (\(fmt(t.confidence)), p \(fmt(top.p)))",
                                      threshold: "conf >= \(fmt(Config.T.targetConfidence)), p >= \(fmt(Config.T.targetTopProb))", pass: false,
                                      note: contenders.count >= 2 ? "ambiguous between \(contenders.count)" : "not confident"))
            if contenders.count >= 2 { return Built(candidate: nil, reason: "which one?", disambiguate: contenders) }
            return wait("not sure which element")


        case "press_enter": return make(.pressEnter, post: "focused field or window changed")
        case "press_escape": return make(.pressEscape, post: "dialog dismissed")
        case "scroll_down", "scroll_up":
            let lvl = Int((a["scroll_amount"]?.score?.score ?? 1).rounded())
            let amount: ScrollAmount = [ScrollAmount.little, .page, .end][min(2, max(0, lvl))]
            reasons.append(GateReason(name: "scroll_amount", value: fmt(a["scroll_amount"]?.score?.score ?? 1), threshold: "rounded", pass: true, note: amount.rawValue))
            return make(.scroll(direction: intent == "scroll_up" ? .up : .down, amount: amount), post: "scroll position changed")
        case "go_back": return make(.goBack, post: "active tab URL changed")
        case "menu_item":
            guard !ctx.menus.isEmpty else {
                // No menu command matches the words; a confidently picked on-screen control with
                // that name does the same job (the targets lab offers no menus at all).
                if let t = a["click_target"]?.choice, t.choice != Questions.targetNone, t.confidence >= Config.T.targetConfidence,
                   let e = ctx.elements.first(where: { $0.id == t.choice }) {
                    reasons.append(GateReason(name: "menu_target", value: "none offered; control \(e.id) '\(e.text)' (\(fmt(t.confidence)))", threshold: fmt(Config.T.targetConfidence), pass: true, note: "no menu command; the visible control instead"))
                    return make(.clickElement(elementId: e.id), target: e.id, post: "'\(e.text)' pressed: focus, window, or value changed")
                }
                reasons.append(GateReason(name: "menu_target", value: "none offered", threshold: "-", pass: false, note: "no menu command matches the words"))
                return wait("no matching menu command")
            }
            guard let m = a["menu_target"]?.choice, m.choice != Questions.targetNone, let item = ctx.menus.first(where: { $0.id == m.choice }) else {
                reasons.append(GateReason(name: "menu_target", value: a["menu_target"]?.choice?.choice ?? "-", threshold: "a listed item", pass: false, note: "which menu command?"))
                return wait("which menu command?")
            }
            let top = m.probabilities[m.choice] ?? 0
            let ok = m.confidence >= Config.T.targetConfidence && top >= Config.T.targetTopProb
            reasons.append(GateReason(name: "menu_target", value: "\(item.id) '\(item.path)' (\(fmt(m.confidence)))", threshold: fmt(Config.T.targetConfidence), pass: ok, note: ok ? "named menu command" : "not sure which"))
            guard ok else {
                let names = m.ranked(excluding: [Questions.targetNone]).prefix(3).compactMap { r in ctx.menus.first { $0.id == r.id }?.path }
                return wait("which menu command: \(names.joined(separator: " / "))?")
            }
            return make(.menuItem(id: item.id, path: item.path), target: item.id, post: "menu command ran: window, focus, or value changed")
        case "confirm", "cancel":
            return wait("nothing pending to \(intent)")
        default:
            return wait("unsupported intent \(intent)")
        }
    }

    /// A follow-up phrase applied to the last action: search terms for a site or search that
    /// was just opened; text for a field that the last action left focused.
    /// "Again" / "once more": re-run the last action. clickElement is refused — its element id is
    /// from a past snapshot and a repeat should not click a stale target; everything else re-runs
    /// (a menu command re-finds its item by path, so "new tab … again" works). A spoken count on
    /// the repeat itself ("twice more") applies to a repeatable action.
    public static func buildRepeat(input: PolicyInput, reasons: inout [GateReason]) -> Built {
        let ctx = input.context
        guard let last = ctx.lastAction else { return Built(candidate: nil, reason: "no recent action to repeat") }
        if case .clickElement = last { return Built(candidate: nil, reason: "cannot repeat a click on a past element") }
        var repeats = 1
        if last.repeatable, let n = Spans.repetitions(in: ctx.rawTranscript) { repeats = n }
        reasons.append(GateReason(name: "followup_target", value: "repeat \(last.summary)", threshold: "-", pass: true, note: repeats > 1 ? "\(repeats)× more" : "once more"))
        return Built(candidate: Candidate(id: Ident.make("c"), snapshotId: input.snapshotId, action: last,
                                          payload: nil, expectedPostcondition: "the previous action ran again", repeats: repeats), reason: nil)
    }

    public static func buildFollowup(input: PolicyInput, reasons: inout [GateReason]) -> Built {
        let ctx = input.context
        func make(_ action: Action, payload: String, post: String) -> Built {
            Built(candidate: Candidate(id: Ident.make("c"), snapshotId: input.snapshotId, action: action, payload: payload, expectedPostcondition: post), reason: nil)
        }
        // The payload is the whole phrase, cleaned; the span head is only a check here.
        let phrase = ctx.rawTranscript.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard !phrase.isEmpty, let last = ctx.lastAction else { return Built(candidate: nil, reason: "no recent action") }
        switch last {
        case .openSite(_, let label), .webSearch(_, _, let label):
            let entry = Config.site(option: label) ?? Config.site(option: Config.defaultSearchSite)!
            guard let template = entry.search else { return Built(candidate: nil, reason: "\(label) cannot be searched") }
            let query = phrase.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? phrase
            reasons.append(GateReason(name: "followup_target", value: "search \(entry.option)", threshold: "-", pass: true, note: "after \(last.summary)"))
            return make(.webSearch(url: template.replacingOccurrences(of: "%s", with: query), query: phrase, site: entry.option), payload: phrase,
                        post: "active tab URL contains \(entry.option) search for the phrase")
        case .openApp, .newNote, .typeText, .clickElement, .pressEnter:
            guard let field = ctx.focusedField, !field.secure, isEditable(field.role) else {
                reasons.append(GateReason(name: "followup_target", value: ctx.focusedField?.role ?? "none", threshold: "editable field focused", pass: false, note: "nowhere to type"))
                return Built(candidate: nil, reason: "no field focused")
            }
            reasons.append(GateReason(name: "followup_target", value: "type into \(field.role)", threshold: "-", pass: true, note: "after \(last.summary)"))
            return make(.typeText(text: phrase), payload: phrase, post: "focused field value contains the phrase")
        default:
            return Built(candidate: nil, reason: "\(last.kind) takes no follow-up")
        }
    }

    /// Query cleanup that code owns (plan section 8: select, then normalize): the site's own name
    /// and its noun ("youtube videos", "on wikipedia"), leading articles and "me", and an
    /// ordering word ("latest", "newest", "recent") which becomes newest-first where the site
    /// supports it. Never touches the middle of the phrase.
    public static func cleanQuery(_ text: String, site: Config.SiteEntry) -> (text: String, newest: Bool, note: String) {
        var words = text.split(separator: " ").map(String.init)
        var notes: [String] = []
        let siteWords: Set<String> = {
            switch site.option {
            case "youtube": return ["youtube", "video", "videos", "on"]
            case "wikipedia": return ["wikipedia", "on"]
            case "google": return ["google", "on"]
            case "github": return ["github", "on"]
            case "reddit": return ["reddit", "on"]
            default: return [site.option, "on"]
            }
        }()
        // Trailing site words: "alex hormozi youtube videos" -> "alex hormozi".
        while let last = words.last, siteWords.contains(last.lowercased()) { words.removeLast(); notes.append("dropped '\(last)'") }
        // Leading site words: "youtube alex hormozi" -> "alex hormozi".
        while let first = words.first, siteWords.contains(first.lowercased()), first.lowercased() != "on" { words.removeFirst(); notes.append("dropped '\(first)'") }
        // Leading articles and "me": "a good pasta recipe" -> "good pasta recipe"; "me some lofi" -> "lofi".
        while let first = words.first, ["a", "an", "the", "some", "me"].contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        var newest = false
        if let i = words.firstIndex(where: { ["latest", "newest", "recent", "new"].contains($0.lowercased()) }), words.count > 1 {
            newest = site.newestSearch != nil
            if newest { words.remove(at: i); notes.append("'latest' -> newest first") }
        }
        let out = words.joined(separator: " ")
        return (out.isEmpty ? text : out, newest, notes.joined(separator: ", "))
    }

    static func isEditable(_ role: String) -> Bool {
        ["textbox", "textarea", "textfield", "searchfield", "combobox", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
    }

    /// Deny list re-check on the built candidate (plan 9.4 step 9).
    public static func denial(for candidate: Candidate, context: DecisionContext) -> String? {
        switch candidate.action {
        case .clickElement(let id):
            if let e = (context.elements + context.offscreen).first(where: { $0.id == id }), Config.isDenied(text: e.text) { return "element '\(e.text)'" }
            if let b = context.frontmostBundleId, Config.denyApps.contains(b) { return "clicks inside \(context.frontmostApp)" }
        case .typeText, .pressEnter:
            if let b = context.frontmostBundleId, Config.denyApps.contains(b) { return "typing inside \(context.frontmostApp)" }
        case .menuItem(_, let path):
            if Config.isMenuDenied(path: path) { return "menu command '\(path)'" }
            if let b = context.frontmostBundleId, Config.denyApps.contains(b) { return "menu commands inside \(context.frontmostApp)" }
        default: break
        }
        return nil
    }
}
