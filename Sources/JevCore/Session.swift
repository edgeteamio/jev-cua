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
                                      targetElementId: e.id, expectedPostcondition: "'\(e.text)' pressed")
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
        guard let u = utterance, inFlight == nil, !executing else { return }
        let now = clock.now()
        let silent = silentMs(now: now)
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
        let observation = await perception.observe()
        let spans = Spans.extract(from: unconsumed)
        var ctx = DecisionContext(rawTranscript: unconsumed, isFinal: isFinal, frontmostApp: observation.app.name,
                                  frontmostBundleId: observation.app.bundleId, focusedField: observation.focusedField,
                                  pendingConfirmation: pending?.action.summary, recentActions: recentActions,
                                  elements: observation.elements, installedApps: Questions.relevantInstalledApps(config.installedApps, transcript: unconsumed),
                                  runningApps: config.runningApps)
        ctx.offscreen = observation.offscreen
        ctx.menus = Questions.relevantMenus(observation.menus, transcript: unconsumed)
        ctx.afterConsumed = !consumedPrefix.isEmpty
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
            onEvent(.error(e.description)); log.log("jev_error", ["error": .string(e.description)]); return
        } catch {
            onEvent(.error("\(error)")); log.log("jev_error", ["error": .string("\(error)")]); return
        }
        if Task.isCancelled { log.recordJevCancelled(); return }
        log.recordJev(resp)

        // Superseded while in flight: still evaluate, but as a non-final, non-silent revision so
        // only allowlisted actions can fire and free text is never truncated (plan 9.4).
        let superseded = utterance?.revision != revision || utterance?.physicalId != utteranceId
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
            let remainder = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            if pending?.id == candidate.id { pending = nil; onEvent(.pendingConfirmation(nil)) }
            await dispatch(candidate, observation: observation, utteranceId: utteranceId, revision: revision, decidedAt: t0)
            if Transcript.wordCount(remainder) >= 2 { rerunRequested = true }
        case .confirm:
            guard let candidate = policy.candidate else { return }
            let remainder = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            pending = candidate; pendingRevision = revision
            onEvent(.pendingConfirmation(candidate))
            if Transcript.wordCount(remainder) >= 2 { rerunRequested = true }
        case .ignore(let reason):
            if reason == "cancelled" { _ = consume(unconsumed, of: unconsumed); pending = nil; onEvent(.pendingConfirmation(nil)) }
            // Chatter judged on a committed clause is done with: consume it so a command that
            // follows in the same breath is judged on its own words ("...go after it | open the
            // Notes app" needed a repeat on 2026-09-20). A partial is left alone: it may still
            // grow into a command.
            else if reason == "not a command", isFinal || silent >= Double(config.silenceCompleteMs), Transcript.wordCount(unconsumed) >= 3 {
                _ = consume(unconsumed, of: unconsumed)
                log.log("chatter_consumed", ["text": log.text(unconsumed)])
            }
        case .wait(let reason, let retry):
            // A wait that names a retry interval (word stability, payload silence) gets one from
            // the next tick after it: revisions may have stopped, and the silence tick is 900 ms away.
            if let retry { retryAt = clock.now() + Double(retry) / 1000 }
            _ = reason
        case .disambiguate(let ids):
            _ = consume(policy.commandSpan ?? unconsumed, of: unconsumed)
            let els = ids.compactMap { id in observation.elements.first { $0.id == id } }
            choices = (els, observation)
            onEvent(.disambiguation(els))
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

    private func dispatch(_ candidate: Candidate, observation: Observation, utteranceId: String, revision: Int, decidedAt: TimeInterval) async {
        executing = true
        defer { executing = false }
        var entry = LedgerEntry(dispatchId: Ident.make("d"), utteranceId: utteranceId, revision: revision, snapshotId: observation.snapshotId,
                                candidateId: candidate.id, dispatchedAt: clock.now(), status: .unknown)
        ledger.append(entry)
        log.recordDispatch(entry)
        let lastWord = utterance?.updatedAt ?? decidedAt
        log.recordLatency(lastWordToDispatchMs: (entry.dispatchedAt - lastWord) * 1000, clauseToResponseMs: nil)
        log.log("dispatch", ["dispatch": .string(entry.dispatchId), "candidate": .string(candidate.id), "action": log.text(candidate.action.summary),
                             "last_word_to_dispatch_ms": .number((entry.dispatchedAt - lastWord) * 1000)])
        onEvent(.dispatched(entry, candidate))

        let outcome = await executor.execute(candidate, observation: observation)
        entry.status = outcome.result.status
        if let i = ledger.firstIndex(where: { $0.dispatchId == entry.dispatchId }) { ledger[i] = entry }
        recentActions.append(candidate.summary)
        if recentActions.count > 3 { recentActions.removeFirst() }
        if outcome.result.status != .failed { lastAction = (candidate.action, clock.now()) }
        log.recordVerification(outcome.verification)
        log.recordLatency(lastWordToDispatchMs: nil, clauseToResponseMs: outcome.verification.outcome == .verified ? (clock.now() - lastWord) * 1000 : nil)
        log.log("executed", ["dispatch": .string(entry.dispatchId), "status": .string(outcome.result.status.rawValue), "detail": .string(outcome.result.detail),
                             "took_ms": .number(outcome.result.tookMs), "verification": .string(outcome.verification.outcome.rawValue),
                             "evidence": .string(outcome.verification.evidence.rawValue), "observed": log.text(outcome.verification.observed)])
        onEvent(.executed(entry, outcome))
        await perception.invalidate()
    }
}
