import Foundation

// The command session (plan sections 3, 9.2, 9.5): utterances, revisions, throttling, one
// in-flight decision plus the latest pending revision, the consumed-prefix ledger, pending
// confirmations, and the hand-off to a serialized executor. Pure Swift, no AppKit, so replay
// fixtures drive it in tests.

// MARK: - Boundaries

public protocol Perceiving: Sendable {
    /// Current observation. Implementations cache for `Config.snapshotTtlMs` and invalidate after actions.
    func observe() async -> Observation
    func invalidate() async
}

public struct ExecutionOutcome: Sendable, Equatable {
    public var result: ActionResult
    public var verification: Verification
    public init(result: ActionResult, verification: Verification) { self.result = result; self.verification = verification }
}

public protocol Executing: Sendable {
    /// Runs exactly one candidate. Writes nothing to the ledger itself; the session owns the entry.
    func execute(_ candidate: Candidate, observation: Observation) async -> ExecutionOutcome
}

public struct TranscriptRevision: Sendable, Equatable, Codable {
    public var utteranceId: String
    public var text: String
    public var isFinal: Bool
    public var at: TimeInterval
    public init(utteranceId: String, text: String, isFinal: Bool, at: TimeInterval) {
        self.utteranceId = utteranceId; self.text = text; self.isFinal = isFinal; self.at = at
    }
}

/// What the session tells the outside world (overlay, spoken feedback, tests).
public enum SessionEvent: Sendable, Equatable {
    case transcript(utteranceId: String, text: String, consumed: String, isFinal: Bool)
    case deciding(utteranceId: String, revision: Int, text: String)
    case decided(Decision, summary: String, candidate: Candidate?)
    case dispatched(LedgerEntry, Candidate)
    case executed(LedgerEntry, ExecutionOutcome)
    case pendingConfirmation(Candidate?)
    /// Numbered choices shown as badges; nil clears them. Elements come from the observation.
    case disambiguation([Element]?)
    case cancelled(reason: String)
    case error(String)
    /// The action a clause will run once the words stop, shown while it waits (a ghost chip);
    /// nil clears it. Sent when the previewed action changes, not on every revision.
    case armed(Candidate?)
    /// Jev cannot be reached (a few words why), or answers again (nil). Sent on changes only.
    case offline(String?)
    /// Example phrases for the app in front, answering "what can I say?".
    case help([String])
    /// A short line for the user that is not a decision: a lapsed confirmation, an undo that
    /// cannot run.
    case notice(String)
}

/// Time source, injectable so replay tests can run instantly.
public protocol Clock: Sendable {
    func now() -> TimeInterval
    func sleep(ms: Int) async
}
public struct SystemClock: Clock {
    public init() {}
    public func now() -> TimeInterval { Mono.now() }
    public func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}

// MARK: - Session

public actor CommandSession {
    public struct Config: Sendable {
        public var throttleMs = JevCore.Config.throttleMs
        public var maxWaitMs = JevCore.Config.maxWaitMs
        public var silenceCompleteMs = JevCore.Config.silenceCompleteMs
        public var installedApps: [String] = []
        public var runningApps: Set<String> = []
        public init() {}
    }

    private let decider: any JevDeciding
    private let perception: any Perceiving
    private let executor: any Executing
    private let log: RunLog
    private let clock: any Clock
    private let config: Config
    private let onEvent: @Sendable (SessionEvent) -> Void

    // Utterance state
    private var utterance: Utterance?
    private var consumedPrefix = ""
    private var consumedGen = 0
    private var previousIntent: String?
    private var lastChangeAt: TimeInterval = 0
    private var lastQuietAt: TimeInterval = 0
    private var pending: Candidate?
    private var pendingRevision: Int = 0
    /// A `.wait` that asked to be re-evaluated: the tick re-decides once this time has passed.
    private var retryAt: TimeInterval?
    /// Badge choices after a `.disambiguate` decision: a spoken number resolves in code.
    private var choices: (elements: [Element], observation: Observation)?
    /// When the pending confirmation was asked; it lapses after `candidateTtlMs`.
    private var pendingAt: TimeInterval = 0
    /// Non-nil while Jev is unreachable: the overlay shows it until the next answer arrives.
    private var outage: String?
    /// The lock screen was in front at the last decision (logged once per change).
    private var screenLocked = false

    /// A decision whose only wait is the commit window (review 2026-09-28, item 1b). Its preview
    /// shows as a ghost chip; when the window passes with the words unchanged, the tick runs the
    /// policy again on these answers and acts, with no second Jev call (live, that call cost ~160
    /// ms whenever the cache missed). Element-targeted actions are shown but decided again at
    /// silence, since their element may have moved.
    private struct Armed {
        var candidate: Candidate
        var utteranceId: String
        var revision: Int
        var consumedGen: Int
        var windowMs: Int
        var direct: Bool
        /// Fired once already for these words and still waiting: leave it to the silence path.
        var fired: Bool
        var unconsumed: String
        var isFinal: Bool
        var observation: Observation
        var spans: SpanSet
        var context: DecisionContext
        var response: JevResponse
    }
    private var armed: Armed?

    // Scheduling
    private var inFlight: Task<Void, Never>?
    private var inFlightRevision: Int?
    private var rerunRequested = false
    private var lastRequestAt: TimeInterval = 0
    private var scheduled: Task<Void, Never>?
    private var executing = false

    // Ledger
    public private(set) var ledger: [LedgerEntry] = []
    public private(set) var recentActions: [String] = []
    private var lastAction: (action: Action, at: TimeInterval)?
    /// The last action while it can still be reversed, with the app it ran in (status menu Undo).
    private var undoable: (action: Action, detail: String, bundleId: String, appName: String)?

    public init(decider: any JevDeciding, perception: any Perceiving, executor: any Executing, log: RunLog,
                clock: any Clock = SystemClock(), config: Config = Config(), onEvent: @escaping @Sendable (SessionEvent) -> Void = { _ in }) {
        self.decider = decider; self.perception = perception; self.executor = executor; self.log = log
        self.clock = clock; self.config = config; self.onEvent = onEvent
    }

    // MARK: Inputs

    /// Called on every recognizer revision (or once, with isFinal, for typed input).
    public func handleTranscript(_ rev: TranscriptRevision) async {
        let now = clock.now()
        if Spans.isKillPhrase(rev.text) {
            await cancelAll(reason: "kill phrase")
            log.log("kill", ["text": log.text(rev.text)])
            return
        }
        if utterance?.physicalId != rev.utteranceId {
            utterance = Utterance(id: rev.utteranceId, physicalId: rev.utteranceId, revision: 0, rawText: rev.text, isFinal: rev.isFinal,
                                  startedAt: now, updatedAt: now)
            consumedPrefix = ""; consumedGen = 0; previousIntent = nil
        } else {
            guard var u = utterance, u.rawText != rev.text || u.isFinal != rev.isFinal else { return }
            // Not sticky: a volatile tail after a finalized chunk makes the utterance non-final again.
            u.revision += 1; u.rawText = rev.text; u.isFinal = rev.isFinal; u.updatedAt = now
            utterance = u
        }
        lastChangeAt = now
        retryAt = nil
        guard let u = utterance else { return }
        // Numbered badges on screen: "two" / "the second one" picks in code, no model call.
        if let c = choices, let n = Self.spokenChoice(rev.text, count: c.elements.count) {
            let e = c.elements[n - 1]
            choices = nil; onEvent(.disambiguation(nil))
            consumedPrefix = u.rawText; consumedGen += 1
            let candidate = Candidate(id: Ident.make("c"), snapshotId: c.observation.snapshotId, action: .clickElement(elementId: e.id),
                                      targetElementId: e.id, expectedPostcondition: "'\(e.text)' pressed", label: e.text)
            log.log("choice", ["number": .number(Double(n)), "element": .string(e.id)])
            await dispatch(candidate, observation: c.observation, utteranceId: u.id, revision: u.revision, decidedAt: now)
            return
        }
        guard let unconsumed = Transcript.stripConsumed(raw: u.rawText, consumedPrefix: consumedPrefix) else {
            log.log("revision_ignored", ["reason": "does not align with consumed prefix", "text": log.text(u.rawText)])
            return
        }
        onEvent(.transcript(utteranceId: u.id, text: unconsumed, consumed: consumedPrefix, isFinal: u.isFinal))
        log.log("transcript", ["utterance": .string(u.id), "revision": .number(Double(u.revision)), "text": log.text(unconsumed), "final": .bool(u.isFinal)])
        // "stop" after a consumed command ("open notes ... stop") is a kill phrase for what remains.
        if !consumedPrefix.isEmpty, Spans.isKillPhrase(unconsumed) {
            await cancelAll(reason: "kill phrase")
            consumedPrefix = u.rawText; consumedGen += 1
            log.log("kill", ["text": log.text(unconsumed)])
            return
        }
        if !consumedPrefix.isEmpty, Transcript.wordCount(unconsumed) < 2 { return }
        if unconsumed.isEmpty { return }
        scheduleDecision(force: u.isFinal)
    }

    /// Audio-level hint from the microphone: the last time the mic was above threshold.
    public func noteAudio(loudAt: TimeInterval?) {
        if let loudAt { lastQuietAt = max(lastQuietAt, loudAt) }
    }

    /// Periodic tick (every ~100 ms from the mic loop, or explicit in tests): re-evaluates a
    /// waiting utterance once the silence window has passed.
    public func tick() async {
        let now = clock.now()
        expirePending(now: now)
        guard let u = utterance, inFlight == nil, !executing else { return }
        let silent = silentMs(now: now)
        // Armed for exactly these words: the commit window decides, on the answers in hand.
        if let a = armed, a.direct, !a.fired, a.utteranceId == u.id, a.revision == u.revision, a.consumedGen == consumedGen, !isConsumedEntirely(u) {
            if silent >= Double(a.windowMs) { await fire(a, silent: silent, stable: (now - lastChangeAt) * 1000); return }
            // An early gate (word settling on a scroll) may still ask to look again sooner.
            if let at = retryAt, now >= at { retryAt = nil; await decide(trigger: "retry") }
            return
        }
        if silent >= Double(config.silenceCompleteMs), !u.rawText.isEmpty, !isConsumedEntirely(u) {
            retryAt = nil
            await decide(trigger: "silence")
        } else if let at = retryAt, now >= at, !isConsumedEntirely(u) {
            retryAt = nil
            await decide(trigger: "retry")
        }
    }

    public func cancelAll(reason: String) async {
        inFlight?.cancel(); inFlight = nil; inFlightRevision = nil
        scheduled?.cancel(); scheduled = nil
        pending = nil
        disarm()
        if choices != nil { choices = nil; onEvent(.disambiguation(nil)) }
        onEvent(.cancelled(reason: reason))
        onEvent(.pendingConfirmation(nil))
        log.log("cancel", ["reason": .string(reason)])
    }

    public var pendingCandidate: Candidate? { pending }

    /// True when the current utterance has no unconsumed words left (or there is none).
    public var isConsumedEntirely: Bool { utterance.map(isConsumedEntirely) ?? true }

    /// The controller closed the utterance (silence boundary, pause): stop deciding on it.
    /// Executions already dispatched finish; a pending confirmation survives so "confirm"
    /// can still arrive as the next utterance.
    public func endUtterance(reason: String) {
        guard let u = utterance else { return }
        scheduled?.cancel(); scheduled = nil
        inFlight?.cancel()
        rerunRequested = false
        let rest = Transcript.stripConsumed(raw: u.rawText, consumedPrefix: consumedPrefix) ?? ""
        log.log("utterance_end", ["utterance": .string(u.id), "reason": .string(reason), "unconsumed": log.text(rest)])
        utterance = nil; consumedPrefix = ""; consumedGen = 0; previousIntent = nil; retryAt = nil
        disarm()
    }

    /// "What can I say?" (spoken, or the status menu): example phrases for the app in front.
    public func showHelp() async {
        let obs = await perception.observe()
        let phrases = Suggestions.phrases(bundleId: obs.app.bundleId, pageHost: obs.pageHost)
        log.log("help", ["app": .string(obs.app.name), "phrases": .number(Double(phrases.count))])
        onEvent(.help(phrases))
    }

    /// The status menu's "Undo last action": the inverse of the last action, in the app it ran
    /// in, through the executor and its verification like any other action.
    public func undoLast() async {
        guard !executing, inFlight == nil else { onEvent(.notice("busy, try again in a moment")); return }
        guard let u = undoable, let inverse = Undo.inverse(of: u.action, detail: u.detail) else { onEvent(.notice("nothing to undo")); return }
        let obs = await perception.observe()
        guard obs.app.bundleId == u.bundleId else { onEvent(.notice("switch back to \(u.appName) to undo")); return }
        undoable = nil
        log.log("undo", ["action": log.text(u.action.summary)])
        let c = Candidate(id: Ident.make("c"), snapshotId: obs.snapshotId, action: inverse, expectedPostcondition: "reversed \(u.action.summary)")
        await dispatch(c, observation: obs, utteranceId: utterance?.id ?? "undo", revision: utterance?.revision ?? 0, decidedAt: clock.now(), spoken: false)
    }

    /// A confirmation nobody answered lapses (review 2026-09-28, item 2c): before this, a "yes"
    /// minutes later still ran it, and the notch stayed open on the prompt.
    private func expirePending(now: TimeInterval) {
        guard let p = pending, (now - pendingAt) * 1000 >= Double(JevCore.Config.candidateTtlMs) else { return }
        pending = nil
        log.log("pending_expired", ["action": log.text(p.action.summary)])
        onEvent(.pendingConfirmation(nil))
        onEvent(.notice("confirmation lapsed: \(p.action.humanLabel)"))
    }

    /// Reports an outage once when it starts and once when Jev answers again.
    private func noteOutage(_ message: String?) {
        guard (outage == nil) != (message == nil) else { return }
        outage = message
        log.log(message == nil ? "online" : "offline", message.map { ["why": .string($0)] } ?? [:])
        onEvent(.offline(message))
    }

    private func disarm() {
        guard armed != nil else { return }
        armed = nil
        onEvent(.armed(nil))
    }

    // MARK: Scheduling

    private func silentMs(now: TimeInterval) -> Double {
        // Silence needs both a stable transcript and a quiet microphone (plan 9.5). Without any
        // audio information (typed input, tests) the transcript alone counts. In a noisy room the
        // mic never goes quiet (a conversation nearby stalled commands for 13 and 53 s on
        // 2026-09-20): once the recognizer has produced no new words for `noisyRoomStableMs`,
        // the transcript alone decides.
        let transcriptStable = (now - lastChangeAt) * 1000
        if transcriptStable >= Double(JevCore.Config.noisyRoomStableMs) { return transcriptStable }
        let quiet = lastQuietAt > 0 ? (now - lastQuietAt) * 1000 : transcriptStable
        return min(transcriptStable, quiet)
    }

    private func isConsumedEntirely(_ u: Utterance) -> Bool {
        guard let rest = Transcript.stripConsumed(raw: u.rawText, consumedPrefix: consumedPrefix) else { return true }
        return rest.isEmpty || (!consumedPrefix.isEmpty && Transcript.wordCount(rest) < 2)
    }

    private func scheduleDecision(force: Bool) {
        scheduled?.cancel()
        let sinceLast = (clock.now() - lastRequestAt) * 1000
        let delay = force ? 0 : max(0, min(config.throttleMs, config.maxWaitMs - Int(sinceLast)))
        if inFlight != nil {
            rerunRequested = true   // the latest pending revision; re-decide when the in-flight one returns
            return
        }
        scheduled = Task { [weak self] in
            if delay > 0 { await self?.clock.sleep(ms: delay) }
            guard !Task.isCancelled else { return }
            await self?.decide(trigger: force ? "final" : "throttle")
            await self?.clearScheduled()
        }
    }

    private func clearScheduled() { scheduled = nil }

    // MARK: Deciding

    private func decide(trigger: String) async {
        guard let u = utterance, inFlight == nil, !executing else { rerunRequested = inFlight != nil; return }
        guard let unconsumed = Transcript.stripConsumed(raw: u.rawText, consumedPrefix: consumedPrefix), !unconsumed.isEmpty else { return }
        // "What can I say?": answered in code, once the phrase has ended (it could still grow).
        if Spans.isHelpPhrase(unconsumed) {
            let silent = silentMs(now: clock.now())
            if u.isFinal || silent >= Double(JevCore.Config.payloadSilenceMs) {
                consume(unconsumed, of: unconsumed)
                await showHelp()
            } else {
                retryAt = clock.now() + Double(JevCore.Config.payloadSilenceMs - Int(silent)) / 1000
            }
            return
        }
        let revision = u.revision
        let isFinal = u.isFinal
        let physicalId = u.physicalId
        let genAtStart = consumedGen
        let silent = silentMs(now: clock.now())
        let stable = (clock.now() - lastChangeAt) * 1000
        lastRequestAt = clock.now()
        inFlightRevision = revision
        onEvent(.deciding(utteranceId: u.id, revision: revision, text: unconsumed))

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDecision(utteranceId: u.id, revision: revision, unconsumed: unconsumed, isFinal: isFinal, silent: silent, stable: stable, trigger: trigger)
        }
        inFlight = task
        await task.value
        inFlight = nil; inFlightRevision = nil
        if rerunRequested {
            rerunRequested = false
            // Re-decide when anything relevant moved while we were busy: a new utterance, a new
            // revision, a final, or a consumption that leaves unconsumed words behind.
            if let now = utterance, now.physicalId != physicalId || now.revision != revision || now.isFinal != isFinal || consumedGen != genAtStart {
                if !isConsumedEntirely(now) { scheduleDecision(force: now.isFinal) }
            }
        }
    }

    /// True when nothing is in flight, scheduled, or executing. Tests use it to settle.
    public var isIdle: Bool { inFlight == nil && scheduled == nil && !executing && !rerunRequested }

    private func runDecision(utteranceId: String, revision: Int, unconsumed: String, isFinal: Bool, silent: Double, stable: Double, trigger: String) async {
        expirePending(now: clock.now())
        let observation = await perception.observe()
        // The screen is locked: nothing may run, and nothing said near a locked Mac goes to Jev.
        if observation.app.bundleId == JevCore.Config.lockScreenBundleId {
            if !screenLocked { screenLocked = true; log.log("screen_locked") }
            if utterance?.physicalId == utteranceId { consume(unconsumed, of: unconsumed) }   // done with: none of it runs later
            return
        }
        if screenLocked { screenLocked = false; log.log("screen_unlocked") }
        let spans = Spans.extract(from: unconsumed)
        var ctx = DecisionContext(rawTranscript: unconsumed, isFinal: isFinal, frontmostApp: observation.app.name,
                                  frontmostBundleId: observation.app.bundleId, focusedField: observation.focusedField,
                                  pendingConfirmation: pending?.action.summary, recentActions: recentActions,
                                  elements: observation.elements, installedApps: Questions.relevantInstalledApps(config.installedApps, transcript: unconsumed),
                                  runningApps: config.runningApps)
        ctx.offscreen = observation.offscreen
        ctx.menus = Questions.relevantMenus(observation.menus, transcript: unconsumed)
        ctx.afterConsumed = !consumedPrefix.isEmpty
        // The front tab's host, never its path or title (goal mode already sends it): an unnamed
        // search stays on the site in front (review 2026-09-28, item 2a).
        ctx.pageHost = observation.pageHost
        if let la = lastAction, clock.now() - la.at <= JevCore.Config.followupWindowS {
            ctx.lastAction = la.action; ctx.lastActionAgeS = clock.now() - la.at
        }
        let relevantApps = Questions.relevantInstalledApps(config.installedApps, transcript: unconsumed)
        let questions = Questions.build(spans: spans, installedApps: relevantApps, runningApps: config.runningApps, rawTranscript: unconsumed,
                                        elements: observation.elements, offscreen: observation.offscreen, followup: ctx.lastAction != nil, menus: ctx.menus)
        let state = StateBuilder.state(for: ctx)
        let t0 = clock.now()
        let resp: JevResponse
        do {
            resp = try await decider.systemOne(state: state, questions: questions, model: nil)
        } catch is CancellationError {
            log.recordJevCancelled(); return
        } catch let e as JevError {
            if case .cancelled = e { log.recordJevCancelled(); return }
            log.log("jev_error", ["error": .string(e.description)])
            // An outage shows until Jev answers again (item 3b); a bad answer is a one-off.
            if e.isOutage { noteOutage(e.outageSummary) } else { onEvent(.error(e.description)) }
            return
        } catch {
            onEvent(.error("\(error)")); log.log("jev_error", ["error": .string("\(error)")]); return
        }
        if Task.isCancelled { log.recordJevCancelled(); return }
        log.recordJev(resp)
        noteOutage(nil)

        // Superseded while in flight: still evaluate, but as a non-final, non-silent revision so
        // only allowlisted actions can fire and free text is never truncated (plan 9.4).
        let superseded = utterance?.revision != revision || utterance?.physicalId != utteranceId
        await conclude(utteranceId: utteranceId, revision: revision, unconsumed: unconsumed, isFinal: isFinal, silent: silent, stable: stable,
                       trigger: trigger, observation: observation, spans: spans, ctx: ctx, resp: resp, superseded: superseded, decidedAt: t0)
    }

    /// Evaluates the policy on answers in hand, logs the decision, and acts on it: for a fresh Jev
    /// answer, and for an armed decision whose commit window just passed.
    private func conclude(utteranceId: String, revision: Int, unconsumed: String, isFinal: Bool, silent: Double, stable: Double, trigger: String,
                          observation: Observation, spans: SpanSet, ctx: DecisionContext, resp: JevResponse, superseded: Bool, decidedAt t0: TimeInterval) async {
        let intent = resp.answers["intent"]?.choice?.choice ?? "none"
        let input = PolicyInput(answers: resp.answers, spans: spans, context: superseded ? { var c = ctx; c.isFinal = false; return c }() : ctx,
                                silentMs: superseded ? 0 : silent, intentStable: previousIntent == intent,
                                pending: pending, snapshotId: observation.snapshotId, transcriptStableMs: superseded ? 0 : stable)
        let policy = Policy.evaluate(input)
        previousIntent = intent

        let decision = Decision(snapshotId: observation.snapshotId, candidateSetId: "cs-\(observation.snapshotId)", utteranceId: utteranceId,
                                revision: revision, intentEpoch: consumedGen, outcome: policy.outcome, answers: resp.answers,
                                reasons: policy.reasons, model: resp.model, latencyMs: resp.latencyMs, usage: resp.usage, requestId: resp.requestId)
        log.recordDecision(policy.outcome.name)
        var record: [String: JSONValue] = [
            "utterance": .string(utteranceId), "revision": .number(Double(revision)), "trigger": .string(trigger),
            "superseded": .bool(superseded), "outcome": .string(policy.outcome.name), "summary": log.text(policy.summary),
            "intent": .string(intent), "latency_ms": .number(resp.latencyMs), "tokens": .number(Double(resp.usage.inputTokens)),
            "reasons": .array(policy.reasons.map { .object(["name": .string($0.name), "value": .string($0.value), "pass": .bool($0.pass)]) }),
            "candidate": policy.candidate.map { .string($0.action.summary) } ?? .null,
        ]
        if !log.redact {
            // Everything `jev-cua replay` needs to re-run the policy with current thresholds.
            record["replay"] = .object(["answers": .encoding(resp.answers), "spans": .encoding(spans), "context": .encoding(input.context),
                                        "silent_ms": .number(input.silentMs), "intent_stable": .bool(input.intentStable),
                                        "pending": pending.map { .encoding($0) } ?? .null, "snapshot": .string(observation.snapshotId)])
        }
        log.log("decision", record)
        onEvent(.decided(decision, summary: policy.summary, candidate: policy.candidate))

        // Only the current utterance may act.
        guard utterance?.physicalId == utteranceId else { return }
        // A new command while badges are showing means the user moved on.
        if choices != nil, policy.outcome.name == "act" || policy.outcome.name == "confirm" { choices = nil; onEvent(.disambiguation(nil)) }
        switch policy.outcome {
        case .act:
            guard let candidate = policy.candidate else { return }
            armed = nil   // no event: the dispatch's chip takes the ghost chip's place
            let remainder = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            if pending?.id == candidate.id { pending = nil; onEvent(.pendingConfirmation(nil)) }
            await dispatch(candidate, observation: observation, utteranceId: utteranceId, revision: revision, decidedAt: t0)
            if Transcript.wordCount(remainder) >= 2 { rerunRequested = true }
        case .confirm:
            guard let candidate = policy.candidate else { return }
            disarm()
            let remainder = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            pending = candidate; pendingRevision = revision; pendingAt = clock.now()
            onEvent(.pendingConfirmation(candidate))
            if Transcript.wordCount(remainder) >= 2 { rerunRequested = true }
        case .ignore(let reason):
            disarm()
            if reason == "cancelled" { _ = consume(unconsumed, of: unconsumed); pending = nil; onEvent(.pendingConfirmation(nil)) }
            // Chatter judged on a committed clause is done with: consume it so a command that
            // follows in the same breath is judged on its own words ("...go after it | open the
            // Notes app" needed a repeat on 2026-09-20). A partial is left alone: it may still
            // grow into a command.
            else if reason == "not a command", isFinal || silent >= Double(config.silenceCompleteMs), Transcript.wordCount(unconsumed) >= 3 {
                _ = consume(unconsumed, of: unconsumed)
                log.log("chatter_consumed", ["text": log.text(unconsumed)])
            }
        case .wait(_, let retry):
            // A wait that names a retry interval (word stability, payload silence) gets one from
            // the next tick after it: revisions may have stopped, and the silence tick is 900 ms away.
            if let retry { retryAt = clock.now() + Double(retry) / 1000 }
            if !superseded {
                updateArmed(policy: policy, input: input, utteranceId: utteranceId, revision: revision, unconsumed: unconsumed, isFinal: isFinal,
                            observation: observation, spans: spans, resp: resp)
            }
        case .disambiguate(let ids):
            disarm()
            _ = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            let els = ids.compactMap { id in observation.elements.first { $0.id == id } }
            choices = (els, observation)
            onEvent(.disambiguation(els))
        }
    }

    /// After a wait: arm the decision when committing is all it waits for; keep an earlier preview
    /// while the words are still coming, so the ghost chip does not blink between revisions; drop
    /// it once the clause waits on the user instead ("search for what?").
    private func updateArmed(policy: PolicyResult, input: PolicyInput, utteranceId: String, revision: Int, unconsumed: String, isFinal: Bool,
                             observation: Observation, spans: SpanSet, resp: JevResponse) {
        guard let candidate = Policy.preview(input) else {
            if Feedback.statusLine(for: policy.outcome, reasons: policy.reasons) != nil { disarm() }
            return
        }
        let direct: Bool
        switch candidate.action {
        case .clickElement, .menuItem: direct = false
        default: direct = candidate.targetElementId == nil
        }
        let sameWords = armed.map { $0.utteranceId == utteranceId && $0.revision == revision && $0.consumedGen == consumedGen } ?? false
        let changed = armed.map { $0.candidate.action != candidate.action || $0.candidate.repeats != candidate.repeats } ?? true
        let window = Policy.commitWindowMs(intent: policy.intent, input: input)
        armed = Armed(candidate: candidate, utteranceId: utteranceId, revision: revision, consumedGen: consumedGen, windowMs: window, direct: direct,
                      fired: sameWords && (armed?.fired ?? false), unconsumed: unconsumed, isFinal: isFinal, observation: observation, spans: spans,
                      context: input.context, response: resp)
        if changed {
            log.log("armed", ["action": log.text(candidate.action.summary), "window_ms": .number(Double(window)), "direct": .bool(direct)])
            onEvent(.armed(candidate))
        }
    }

    /// The armed decision's commit window passed with the words unchanged: run the policy again on
    /// its answers, now silent, and act. No model call; logged with trigger "armed". Once per
    /// revision: if it still waits, the ordinary silence and retry path takes over.
    private func fire(_ a: Armed, silent: Double, stable: Double) async {
        armed?.fired = true
        retryAt = nil
        var resp = a.response
        resp.latencyMs = 0; resp.usage = Usage(inputTokens: 0, outputTokens: 0)   // no call was made
        await conclude(utteranceId: a.utteranceId, revision: a.revision, unconsumed: a.unconsumed, isFinal: a.isFinal, silent: silent, stable: stable,
                       trigger: "armed", observation: a.observation, spans: a.spans, ctx: a.context, resp: resp, superseded: false, decidedAt: clock.now())
        if rerunRequested {
            rerunRequested = false
            if let now = utterance, !isConsumedEntirely(now) { scheduleDecision(force: now.isFinal) }
        }
    }

    /// "two", "the second one", "number 3", "click the first" -> 1-based index within `count`.
    static func spokenChoice(_ raw: String, count: Int) -> Int? {
        let words = Transcript.normalize(raw).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        let ordinals: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        // "the second one": the ordinal is the pick and "one" is filler.
        let numberWords = words.filter { w in Spans.numberWord(w) != nil && !(w == "one" && words.contains(where: ordinals.contains)) }
        guard numberWords.count == 1, let n = Spans.numberWord(numberWords[0]), (1...count).contains(n) else { return nil }
        let filler: Set<String> = ["the", "number", "one", "option", "click", "press", "choose", "select", "pick", "that", "please", "um", "uh", "item"]
        let others = words.filter { Spans.numberWord($0) == nil && !filler.contains($0) }
        return others.isEmpty ? n : nil
    }

    /// Marks `text` (a prefix of `whole`) as acted on. Returns what is left of `whole`.
    @discardableResult
    private func consume(_ text: String, of whole: String) -> String {
        consumedPrefix = (consumedPrefix + " " + text).trimmingCharacters(in: .whitespaces)
        consumedGen += 1
        previousIntent = nil
        log.log("consumed", ["prefix": log.text(text)])
        return Transcript.stripConsumed(raw: whole, consumedPrefix: text) ?? ""
    }

    // MARK: Dispatch

    /// `spoken` is false for an action from the status menu (Undo): no last word to time it from.
    private func dispatch(_ candidate: Candidate, observation: Observation, utteranceId: String, revision: Int, decidedAt: TimeInterval, spoken: Bool = true) async {
        executing = true
        defer { executing = false }
        var entry = LedgerEntry(dispatchId: Ident.make("d"), utteranceId: utteranceId, revision: revision, snapshotId: observation.snapshotId,
                                candidateId: candidate.id, dispatchedAt: clock.now(), status: .unknown)
        ledger.append(entry)
        log.recordDispatch(entry)
        let lastWord = spoken ? (utterance?.updatedAt ?? decidedAt) : decidedAt
        if spoken { log.recordLatency(lastWordToDispatchMs: (entry.dispatchedAt - lastWord) * 1000, clauseToResponseMs: nil) }
        log.log("dispatch", ["dispatch": .string(entry.dispatchId), "candidate": .string(candidate.id), "action": log.text(candidate.action.summary),
                             "last_word_to_dispatch_ms": .number((entry.dispatchedAt - lastWord) * 1000)])
        onEvent(.dispatched(entry, candidate))

        let outcome = await executor.execute(candidate, observation: observation)
        entry.status = outcome.result.status
        if let i = ledger.firstIndex(where: { $0.dispatchId == entry.dispatchId }) { ledger[i] = entry }
        recentActions.append(candidate.summary)
        if recentActions.count > 3 { recentActions.removeFirst() }
        if outcome.result.status != .failed { lastAction = (candidate.action, clock.now()) }
        // Only the newest action can be undone, and only one with a safe inverse: Edit › Undo
        // after a click or a key could reverse something that was not ours.
        if outcome.result.status == .acknowledged, outcome.verification.outcome != .failed,
           Undo.inverse(of: candidate.action, detail: outcome.result.detail) != nil {
            undoable = (candidate.action, outcome.result.detail, observation.app.bundleId, observation.app.name)
        } else {
            undoable = nil
        }
        log.recordVerification(outcome.verification)
        if spoken { log.recordLatency(lastWordToDispatchMs: nil, clauseToResponseMs: outcome.verification.outcome == .verified ? (clock.now() - lastWord) * 1000 : nil) }
        log.log("executed", ["dispatch": .string(entry.dispatchId), "status": .string(outcome.result.status.rawValue), "detail": .string(outcome.result.detail),
                             "took_ms": .number(outcome.result.tookMs), "verification": .string(outcome.verification.outcome.rawValue),
                             "evidence": .string(outcome.verification.evidence.rawValue), "observed": log.text(outcome.verification.observed)])
        onEvent(.executed(entry, outcome))
        await perception.invalidate()
    }
}
