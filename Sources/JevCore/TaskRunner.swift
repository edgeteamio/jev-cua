import Foundation

/// Goal mode (plan Phase 6): a typed goal → subgoal loop over the same Observation → Candidate →
/// Executor → Verify chain as CommandSession, with Jev's three gates (`goal_achieved`,
/// `blocked`, `needs_reobserve`) and `next_action` per step, stop rules (confidence floor, two
/// consecutive no-ops, step and time budgets), and escalation hooks behind a budget that are
/// visible in the trace.
public actor TaskRunner {
    public struct Config: Sendable {
        public var installedApps: [String] = []
        public var runningApps: Set<String> = []
        /// Skip the intake questions (missing detail, compound) — tests and scripted suites.
        public var skipIntake = false
        public init() {}
    }

    private let decider: any JevDeciding
    private let perception: any Perceiving
    private let executor: any Executing
    private let escalation: (any Escalating)?
    private let log: RunLog
    private let clock: any Clock
    private let config: Config
    private let onStep: @Sendable (GoalStep) -> Void
    private var cancelled = false

    public init(decider: any JevDeciding, perception: any Perceiving, executor: any Executing, escalation: (any Escalating)? = nil,
                log: RunLog, clock: any Clock = SystemClock(), config: Config = Config(), onStep: @escaping @Sendable (GoalStep) -> Void = { _ in }) {
        self.decider = decider; self.perception = perception; self.executor = executor; self.escalation = escalation
        self.log = log; self.clock = clock; self.config = config; self.onStep = onStep
    }

    public func cancel() { cancelled = true }

    /// One request, retried once when the service returns an inconsistent answer (a choice that
    /// is not the argmax; seen a few times per thousand calls). The retry is logged.
    private func ask(_ state: JSONValue, _ questions: [String: Question]) async throws -> JevResponse {
        do { return try await decider.systemOne(state: state, questions: questions, model: nil) }
        catch let JevError.malformed(m) {
            log.log("jev_malformed_retry", ["detail": .string(m.description)])
            return try await decider.systemOne(state: state, questions: questions, model: nil)
        }
    }

    public func run(_ specIn: TaskSpec) async -> GoalResult {
        var spec = specIn
        let t0 = clock.now()
        var steps: [GoalStep] = []
        var escalations = 0
        var cost = 0.0
        var history: [String] = []
        var observationsSeen: [String] = []
        var lastVerified = false
        log.log("goal_start", ["task": .string(spec.id), "goal": log.text(spec.goal)])

        func finish(_ outcome: GoalResult.Outcome, _ detail: String, answer: String? = nil) -> GoalResult {
            log.log("goal_end", ["task": .string(spec.id), "outcome": .string(outcome.rawValue), "detail": log.text(detail), "steps": .number(Double(steps.count)),
                                 "escalations": .number(Double(escalations)), "cost_usd": .number(cost)])
            return GoalResult(task: spec, outcome: outcome, detail: detail, steps: steps, escalations: escalations, costUSD: cost,
                              elapsedS: clock.now() - t0, answer: answer)
        }
        func record(_ step: GoalStep) {
            steps.append(step)
            log.log("goal_step", ["task": .string(spec.id), "index": .number(Double(step.index)), "kind": .string(step.kind.rawValue), "subgoal": log.text(step.subgoal),
                                  "summary": log.text(step.summary), "action": step.action.map { .string($0) } ?? .null,
                                  "verification": step.verification.map { .string($0) } ?? .null, "latency_ms": .number(step.latencyMs),
                                  "tokens": .number(Double(step.inputTokens)), "escalation": step.escalation.map { .string($0) } ?? .null,
                                  "reasons": .array(step.reasons.map { .object(["name": .string($0.name), "value": .string($0.value), "pass": .bool($0.pass)]) })])
            onStep(step)
        }

        // Intake: a missing detail ends the run with one clarifying question; a compound goal is
        // split by the planner when one is available within budget, else run as one subgoal.
        if !config.skipIntake {
            do {
                let resp = try await ask(["goal": .string(spec.goal)], Questions.buildGoalIntake())
                cost += resp.usage.costUSD
                if let m = resp.answers["goal_missing"]?.choice, m.choice != "nothing", m.confidence >= JevCore.Config.Goal.missingThreshold {
                    let ask = "Which \(m.choice.replacingOccurrences(of: "_", with: " "))?"
                    record(GoalStep(index: 0, subgoal: spec.goal, kind: .clarify, summary: ask, action: nil, verification: nil,
                                    reasons: [GateReason(name: "goal_missing", value: "\(m.choice) (\(String(format: "%.2f", m.confidence)))", threshold: "\(JevCore.Config.Goal.missingThreshold)", pass: false, note: "asks the user")],
                                    latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: nil))
                    return finish(.needsClarification, ask)
                }
                let compound = resp.answers["goal_compound"]?.noul ?? 0
                if compound >= 0.6, spec.subgoals.isEmpty, let esc = escalation, escalations < spec.escalationBudget {
                    escalations += 1
                    if let plan = try? await esc.plan(goal: spec.goal), plan.count >= 2 {
                        spec.subgoals = plan
                        record(GoalStep(index: 0, subgoal: spec.goal, kind: .stop, summary: "planned \(plan.count) subgoals", action: nil, verification: nil,
                                        reasons: [GateReason(name: "goal_compound", value: String(format: "%.2f", compound), threshold: "0.60", pass: true, note: "planner used")],
                                        latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: "\(esc.name) plan"))
                    }
                }
            } catch {
                return finish(.failed, "intake: \(error)")
            }
        }
        if spec.subgoals.isEmpty { spec.subgoals = [spec.goal] }

        var index = 0
        var consecutiveNoOps = 0
        var consecutiveFailures = 0
        var reobserves = 0
        var writerCache: (input: String, text: String)? = nil
        var lastTypedClause: Int? = nil

        for subgoal in spec.subgoals {
            var subgoalDone = false
            while !subgoalDone {
                if cancelled { return finish(.cancelled, "cancelled") }
                if index >= spec.stepBudget { return finish(.budgetExhausted, "step budget \(spec.stepBudget) reached") }
                if clock.now() - t0 > spec.timeBudgetS { return finish(.budgetExhausted, "time budget \(Int(spec.timeBudgetS)) s reached") }
                index += 1

                let observation = await perception.observe()
                // Spans and payloads come from one clause of the subgoal at a time. The clause is
                // chosen in the same request (clause head), so the spans offered cover every
                // clause and the pick is applied afterwards.
                let clauses = Questions.goalClauses(subgoal)
                let spans = Spans.extract(from: subgoal)
                let relevantApps = Questions.relevantInstalledApps(config.installedApps, transcript: subgoal)
                var ctx = DecisionContext(rawTranscript: subgoal, isFinal: true, frontmostApp: observation.app.name, frontmostBundleId: observation.app.bundleId,
                                          focusedField: observation.focusedField, recentActions: Array(history.suffix(3)), elements: observation.elements,
                                          installedApps: relevantApps, runningApps: config.runningApps)
                ctx.offscreen = observation.offscreen
                ctx.pageHost = observation.pageHost
                ctx.menus = Questions.relevantMenus(observation.menus, transcript: subgoal)
                observationsSeen.append("\(observation.app.name): \(observation.elements.prefix(12).map { Questions.describe($0) }.joined(separator: "; "))")
                let state = GoalState.state(goal: spec.goal, subgoal: subgoal, step: index, history: history, context: ctx, clauses: clauses)
                let questions = Questions.buildGoalStep(spans: spans, goalText: subgoal, installedApps: relevantApps, runningApps: config.runningApps,
                                                        elements: observation.elements, offscreen: observation.offscreen, clauses: clauses, menus: ctx.menus)
                let resp: JevResponse
                do { resp = try await ask(state, questions) }
                catch { return finish(.failed, "jev: \(error)") }
                cost += resp.usage.costUSD
                log.recordJev(resp)
                let a = resp.answers
                var reasons: [GateReason] = []
                func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

                // Gates.
                let achieved = a["goal_achieved"]?.noul ?? 0
                let nextPick = a["next_action"]?.choice
                // Achieved outright, or both heads agree there is nothing left to do right after a
                // verified action (achieved leaning yes, next action abstaining).
                // ... or the next action would merely repeat the action just verified.
                let repeatsVerified = lastVerified && history.last.map { last in nextPick.map { last.contains("] " + $0.choice) || last.hasPrefix($0.choice) } ?? false } == true
                    && clauses.count <= 1 + history.count   // every clause has had its turn
                let agreedDone = achieved >= 0.40 && lastVerified && !history.isEmpty
                    && ((nextPick?.choice == Questions.nextActionAbstain && (nextPick?.confidence ?? 0) >= 0.45) || repeatsVerified)
                reasons.append(GateReason(name: "goal_achieved", value: fmt(achieved), threshold: fmt(JevCore.Config.Goal.achievedThreshold), pass: achieved >= JevCore.Config.Goal.achievedThreshold || agreedDone,
                                          note: agreedDone ? "achieved leaning yes and next action abstains after a verified step" : "done on this screen"))
                if achieved >= JevCore.Config.Goal.achievedThreshold || agreedDone {
                    record(GoalStep(index: index, subgoal: subgoal, kind: .achieved, summary: "achieved", action: nil, verification: nil, reasons: reasons,
                                    latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: nil))
                    subgoalDone = true; consecutiveNoOps = 0; continue
                }
                let blocked = a["blocked"]?.noul ?? 0
                reasons.append(GateReason(name: "blocked", value: fmt(blocked), threshold: fmt(JevCore.Config.Goal.blockedThreshold), pass: blocked < JevCore.Config.Goal.blockedThreshold, note: "no wall or dialog in the way"))
                if blocked >= JevCore.Config.Goal.blockedThreshold {
                    record(GoalStep(index: index, subgoal: subgoal, kind: .blocked, summary: "blocked", action: nil, verification: nil, reasons: reasons,
                                    latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: nil))
                    return finish(.blocked, "blocked on this screen; the user has to intervene")
                }
                let reobserve = a["needs_reobserve"]?.noul ?? 0
                let next = a["next_action"]?.choice
                let nextId = next?.choice ?? Questions.nextActionAbstain
                let nextConf = next?.confidence ?? 0
                // A look is only worth taking when something happened since the last one: never on a
                // fresh goal, never twice in a row.
                let lookWorthwhile = !history.isEmpty && steps.last?.kind != .reobserve
                if lookWorthwhile, (reobserve >= JevCore.Config.Goal.reobserveThreshold || nextId == Questions.nextActionReobserve), reobserves < JevCore.Config.Goal.maxReobserves {
                    reasons.append(GateReason(name: "needs_reobserve", value: fmt(reobserve), threshold: fmt(JevCore.Config.Goal.reobserveThreshold), pass: false, note: "look again"))
                    reobserves += 1; consecutiveNoOps += 1
                    await clock.sleep(ms: JevCore.Config.Goal.reobserveDelayMs)   // a look later, not the same look again
                    await perception.invalidate()
                    record(GoalStep(index: index, subgoal: subgoal, kind: .reobserve, summary: "reobserve", action: nil, verification: nil, reasons: reasons,
                                    latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: nil))
                    if consecutiveNoOps >= JevCore.Config.Goal.maxConsecutiveNoOps { return finish(.abstained, "no progress after \(consecutiveNoOps) looks") }
                    continue
                }
                let ranked = next?.ranked() ?? []
                let top3 = ranked.prefix(3).map { "\($0.id) \(fmt($0.p))" }.joined(separator: ", ")
                // Two acceptable reversible moves splitting the mass ("open notes" 0.40 vs "new note"
                // 0.31 as a first step) is a preference tie, not doubt: take the top one.
                let reversible: Set<String> = ["open_app", "new_note", "open_site", "web_search", "scroll_down", "scroll_up", "press_escape", "go_back"]
                let tieOfReversibles = ranked.count >= 2 && reversible.contains(ranked[0].id) && reversible.contains(ranked[1].id) && ranked[0].p + ranked[1].p >= 0.6 && ranked[0].id == nextId
                let confident = nextConf >= JevCore.Config.Goal.nextActionConfidence || tieOfReversibles
                reasons.append(GateReason(name: "next_action", value: "\(nextId) (\(fmt(nextConf))) [\(top3)]", threshold: fmt(JevCore.Config.Goal.nextActionConfidence),
                                          pass: nextId != Questions.nextActionAbstain && confident, note: tieOfReversibles && nextConf < JevCore.Config.Goal.nextActionConfidence ? "tie between reversible moves, top taken" : "one step forward"))
                if nextId == Questions.nextActionAbstain || nextId == Questions.nextActionReobserve || !confident {
                    consecutiveNoOps += 1
                    record(GoalStep(index: index, subgoal: subgoal, kind: .abstain, summary: nextId == Questions.nextActionAbstain ? "abstain" : "next action not confident",
                                    action: nil, verification: nil, reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: nil))
                    if consecutiveNoOps >= JevCore.Config.Goal.maxConsecutiveNoOps { return finish(.abstained, "no confident next step") }
                    continue
                }

                // Phase B for a multi-clause goal: the chosen clause becomes `transcript` and the
                // argument heads (app, site, spans, targets) are asked again over it, so "switch
                // back to notes" resolves to Notes and a query never reaches into a later step.
                var clauseSpans = spans
                var clauseCtx = ctx
                var answers = a
                var clauseIndex: Int? = nil
                if clauses.count >= 2, let pick = a["clause"]?.choice, let idx = Int(pick.choice.dropFirst()), idx >= 1, idx <= clauses.count {
                    let clause = clauses[idx - 1]
                    clauseIndex = idx
                    reasons.append(GateReason(name: "clause", value: "c\(idx) '\(clause)' (\(fmt(pick.confidence)))", threshold: "-", pass: true, note: "arguments read from this clause"))
                    clauseSpans = Spans.extract(from: clause)
                    clauseCtx.rawTranscript = clause
                    clauseCtx.menus = Questions.relevantMenus(observation.menus, transcript: clause)
                    let argQuestions = Questions.buildClauseArguments(spans: clauseSpans, installedApps: relevantApps, runningApps: config.runningApps,
                                                                      elements: observation.elements, offscreen: observation.offscreen, menus: clauseCtx.menus)
                    let argState = GoalState.state(goal: spec.goal, subgoal: subgoal, step: index, history: history, context: clauseCtx, clauses: clauses, transcript: clause)
                    do {
                        let argResp = try await ask(argState, argQuestions)
                        cost += argResp.usage.costUSD
                        log.recordJev(argResp)
                        for (k, v) in argResp.answers { answers[k] = v }
                        reasons.append(GateReason(name: "clause_arguments", value: "\(argResp.usage.inputTokens) tokens", threshold: "-", pass: true, note: String(format: "%.0f ms", argResp.latencyMs)))
                    } catch { return finish(.failed, "jev: \(error)") }
                }
                // Build the candidate in code from the picked heads; the writer fills free text
                // that no span covers, within the escalation budget.
                let input = PolicyInput(answers: answers, spans: clauseSpans, context: clauseCtx, silentMs: 1000, intentStable: true, snapshotId: observation.snapshotId, transcriptStableMs: 1000)
                var built = CandidateBuilder.build(intent: nextId, input: input, reasons: &reasons)
                // The clause head can lag next_action by one step ("open chrome" picked while Chrome is
                // already in front and next_action says web_search): try the following clause once.
                if built.candidate == nil, let idx = clauseIndex, idx < clauses.count, ["web_search", "open_site", "type_text", "open_app"].contains(nextId) {
                    let nextClause = clauses[idx]
                    let nextSpans = Spans.extract(from: nextClause)
                    var nextCtx = clauseCtx; nextCtx.rawTranscript = nextClause
                    nextCtx.menus = Questions.relevantMenus(observation.menus, transcript: nextClause)
                    let argQuestions = Questions.buildClauseArguments(spans: nextSpans, installedApps: relevantApps, runningApps: config.runningApps,
                                                                      elements: observation.elements, offscreen: observation.offscreen, menus: nextCtx.menus)
                    let argState = GoalState.state(goal: spec.goal, subgoal: subgoal, step: index, history: history, context: nextCtx, clauses: clauses, transcript: nextClause)
                    if let argResp = try? await ask(argState, argQuestions) {
                        cost += argResp.usage.costUSD
                        log.recordJev(argResp)
                        var retryAnswers = answers
                        for (k, v) in argResp.answers { retryAnswers[k] = v }
                        var retryReasons: [GateReason] = []
                        let retry = CandidateBuilder.build(intent: nextId, input: PolicyInput(answers: retryAnswers, spans: nextSpans, context: nextCtx, silentMs: 1000, intentStable: true, snapshotId: observation.snapshotId, transcriptStableMs: 1000), reasons: &retryReasons)
                        if retry.candidate != nil {
                            built = retry; clauseIndex = idx + 1; clauseSpans = nextSpans; clauseCtx = nextCtx
                            reasons.append(GateReason(name: "clause", value: "c\(idx + 1) '\(nextClause)'", threshold: "-", pass: true, note: "next clause, since c\(idx) gave no argument for \(nextId)"))
                            reasons += retryReasons
                        }
                    }
                }
                var escalationNote: String? = nil
                if built.candidate == nil, nextId == "type_text", let esc = escalation, escalations < spec.escalationBudget,
                   let field = ctx.focusedField, !field.secure, CandidateBuilder.isEditable(field.role) {
                    let key = [spec.goal, subgoal, field.role, field.label ?? "", field.placeholder ?? "", ctx.frontmostApp, history.joined(separator: "|")].joined(separator: "\u{1F}")
                    var text: String? = writerCache?.input == key ? writerCache?.text : nil
                    if text == nil {
                        escalations += 1
                        text = try? await esc.write(goal: spec.goal, field: field, app: ctx.frontmostApp, history: history)
                        if let text { writerCache = (key, text) }
                    }
                    if let text, !text.isEmpty {
                        escalationNote = "\(esc.name) write (\(text.count) chars)"
                        built = CandidateBuilder.Built(candidate: Candidate(id: Ident.make("c"), snapshotId: observation.snapshotId, action: .typeText(text: text),
                                                                            payload: text, expectedPostcondition: "focused field value contains the text"), reason: nil)
                    }
                }
                // Text for a later clause than the last typed one starts on a new line: a note's
                // body under its title, not glued to it.
                if var cand = built.candidate, case .typeText(let t, .insert) = cand.action, !t.hasPrefix("\n"),
                   let idx = clauseIndex, let prev = lastTypedClause, idx > prev,
                   let last = history.last, last.contains("type_text"), last.contains("verified") {
                    // The text area the body goes into: a named target's role, else the focused
                    // field's. A note is one multi-line text area holding both title and body, so
                    // a later clause typed into it must start below what is there, whether Jev
                    // named the field or left it to focus. Single-line fields (a form) never do.
                    let role = cand.targetElementId.flatMap { id in observation.elements.first { $0.id == id }?.role } ?? ctx.focusedField?.role
                    if role == "textarea" {
                        cand.action = .typeText(text: "\n" + t, placement: .insert); cand.payload = t
                        built.candidate = cand
                        reasons.append(GateReason(name: "new_line", value: "clause \(idx) after clause \(prev)", threshold: "-", pass: true, note: "Return before the text (textarea body)"))
                    }
                }
                if built.candidate != nil, case .typeText = built.candidate!.action, let idx = clauseIndex { lastTypedClause = idx }
                // An ambiguous click target in goal mode is a question for the user, with the choices named.
                if built.candidate == nil, built.disambiguate.count >= 2 {
                    let names = built.disambiguate.compactMap { id in observation.elements.first { $0.id == id }.map { "\($0.role) '\($0.text)'" } }
                    record(GoalStep(index: index, subgoal: subgoal, kind: .clarify, summary: "which one: \(names.joined(separator: " / "))", action: nil, verification: nil,
                                    reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    return finish(.needsClarification, "which one: \(names.joined(separator: " / "))?")
                }
                guard let candidate = built.candidate else {
                    consecutiveNoOps += 1
                    record(GoalStep(index: index, subgoal: subgoal, kind: .abstain, summary: built.reason ?? "no candidate", action: nil, verification: nil,
                                    reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    if consecutiveNoOps >= JevCore.Config.Goal.maxConsecutiveNoOps { return finish(.abstained, built.reason ?? "no candidate") }
                    continue
                }
                if history.suffix(3).contains(where: { $0.contains(candidate.action.summary + ": verified") }), !GoalState.asksToRepeat(subgoal) {
                    consecutiveNoOps += 1
                    record(GoalStep(index: index, subgoal: subgoal, kind: .abstain, summary: "would repeat \(candidate.action.summary), already verified", action: nil,
                                    verification: nil, reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    if consecutiveNoOps >= JevCore.Config.Goal.maxConsecutiveNoOps { return finish(.abstained, "next step would only repeat \(candidate.action.summary)") }
                    continue
                }
                if let last = history.last, last.contains(candidate.action.summary + ": unknown") {
                    record(GoalStep(index: index, subgoal: subgoal, kind: .clarify, summary: "would repeat \(candidate.action.summary), whose outcome is unknown", action: nil,
                                    verification: nil, reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    return finish(.needsClarification, "did \(candidate.action.summary) work? its outcome could not be verified")
                }
                // Gated tier needs the user in goal mode: stop and say so. Deny list is final.
                if candidate.tier == .gated, (a["destructive"]?.noul ?? 0) >= JevCore.Config.T.destructive {
                    record(GoalStep(index: index, subgoal: subgoal, kind: .clarify, summary: "needs confirmation: \(candidate.action.summary)", action: candidate.action.summary,
                                    verification: nil, reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    return finish(.needsClarification, "confirm \(candidate.action.summary)?")
                }
                if let denial = CandidateBuilder.denial(for: candidate, context: ctx) {
                    record(GoalStep(index: index, subgoal: subgoal, kind: .stop, summary: "denied: \(denial)", action: candidate.action.summary, verification: nil,
                                    reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                    return finish(.blocked, "denied by policy: \(denial)")
                }

                let entry = LedgerEntry(dispatchId: Ident.make("d"), utteranceId: spec.id, revision: index, snapshotId: observation.snapshotId,
                                        candidateId: candidate.id, dispatchedAt: clock.now(), status: .unknown)
                log.recordDispatch(entry)
                let outcome = await executor.execute(candidate, observation: observation)
                log.recordVerification(outcome.verification)
                log.log("executed", ["dispatch": .string(entry.dispatchId), "status": .string(outcome.result.status.rawValue), "detail": .string(outcome.result.detail),
                                     "took_ms": .number(outcome.result.tookMs), "verification": .string(outcome.verification.outcome.rawValue),
                                     "evidence": .string(outcome.verification.evidence.rawValue), "observed": log.text(outcome.verification.observed)])
                await perception.invalidate()
                let v = outcome.verification.outcome.rawValue
                // History names the clause the action served, so the next step can see which
                // clauses are done ("[return to notes] open_app Notes: verified").
                let clauseTag = clauseIndex.map { "[\(clauses[$0 - 1])] " } ?? ""
                history.append("\(clauseTag)\(candidate.action.summary): \(v)\(outcome.verification.observed.isEmpty ? "" : " (\(outcome.verification.observed))")")
                if history.count > 6 { history.removeFirst() }
                lastVerified = outcome.verification.outcome == .verified
                writerCache = outcome.result.status == .acknowledged && outcome.verification.outcome != .failed ? nil : writerCache
                consecutiveNoOps = 0; reobserves = 0
                consecutiveFailures = outcome.verification.outcome == .failed ? consecutiveFailures + 1 : 0
                record(GoalStep(index: index, subgoal: subgoal, kind: .act, summary: candidate.action.summary, action: candidate.action.summary,
                                verification: "\(v) via \(outcome.verification.evidence.rawValue): \(outcome.result.detail)\(outcome.verification.observed.isEmpty ? "" : " — \(outcome.verification.observed)")",
                                reasons: reasons, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, escalation: escalationNote))
                if consecutiveFailures >= 2 { return finish(.failed, "two consecutive failed actions") }
            }
        }

        // An information goal gets its answer composed from what was seen, only after a verified run.
        var answer: String? = nil
        if GoalState.isQuestion(spec.goal), let esc = escalation, escalations < spec.escalationBudget, lastVerified {
            escalations += 1
            answer = try? await esc.compose(goal: spec.goal, observations: observationsSeen.suffix(3).map { $0 }, history: history)
        }
        return finish(.achieved, "all subgoals achieved", answer: answer)
    }
}

/// State for a goal-mode step (plan section 6 shape, goal fields added).
public enum GoalState {
    public static func state(goal: String, subgoal: String, step: Int, history: [String], context ctx: DecisionContext, clauses: [String] = [], transcript: String? = nil) -> JSONValue {
        var s = StateBuilder.state(for: ctx).objectValue ?? [:]
        s["transcript_is_final"] = nil; s["pending_confirmation"] = nil; s["recent_actions"] = nil; s["last_action"] = nil
        // The words the argument heads read: the current clause when known, else the subgoal.
        s["transcript"] = .string(Transcript.normalize(transcript ?? subgoal))
        s["goal"] = .string(goal)
        s["subgoal"] = .string(subgoal)
        s["clauses"] = .array((clauses.isEmpty ? [subgoal] : clauses).map(JSONValue.string))
        s["step"] = .number(Double(step))
        s["history"] = .array(history.map(JSONValue.string))
        return .object(s)
    }

    /// "twice", "again", "three times", "two photos": the goal itself asks for a repeat.
    public static func asksToRepeat(_ goal: String) -> Bool {
        let g = Transcript.normalize(goal)
        return ["twice", "again", "times", "two photos", "three photos", "more"].contains { g.contains($0) }
    }

    public static func isQuestion(_ goal: String) -> Bool {
        let first = Transcript.normalize(goal).split(separator: " ").first.map(String.init) ?? ""
        return ["who", "what", "when", "where", "why", "how", "is", "are", "does", "do", "which", "whats", "what's"].contains(first) || goal.hasSuffix("?")
    }
}
