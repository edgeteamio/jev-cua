import Foundation
import os
import Testing
@testable import JevCore

/// Scripted stand-in for Jev in goal mode: answers the gates and next action from the state
/// (frontmost app, history, elements), shaped like real answers.
final class FakeGoalJev: JevDeciding, @unchecked Sendable {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    var missing: String = "nothing"
    var compound: Double = 0.1
    /// Rule: given (frontmost app, history, element texts) → (achieved, blocked, reobserve, next, conf).
    var rule: @Sendable (String, [String], [String]) -> (Double, Double, Double, String, Double) = { app, history, _ in
        if history.contains(where: { $0.hasPrefix("new_note") }) { return (0.95, 0.05, 0.1, "abstain", 0.9) }
        if app == "Notes" { return (0.1, 0.05, 0.1, "new_note", 0.9) }
        return (0.05, 0.05, 0.1, "open_app", 0.95)
    }

    func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse {
        calls.withLock { $0 += 1 }
        var answers: [String: Answer] = [:]
        if questions["goal_missing"] != nil {
            answers["goal_missing"] = FakeJev.choice(ChoiceQuestion("", criteria: Dictionary(uniqueKeysWithValues: Questions.goalMissingOptions.map { ($0, JSONValue.null) })), pick: missing, conf: 0.9)
            answers["goal_compound"] = .noul(compound)
            return JevResponse(model: "fake", answers: answers, usage: Usage(inputTokens: 50, outputTokens: 1), latencyMs: 1, requestId: nil)
        }
        let app = state["frontmost_app"]?.stringValue ?? ""
        let history = state["history"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let elements = state["elements"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let (achieved, blocked, reobserve, next, conf) = rule(app, history, elements)
        for (id, q) in questions {
            switch (id, q) {
            case ("goal_achieved", .noul): answers[id] = .noul(achieved)
            case ("blocked", .noul): answers[id] = .noul(blocked)
            case ("needs_reobserve", .noul): answers[id] = .noul(reobserve)
            case ("destructive", .noul): answers[id] = .noul(0.05)
            case ("next_action", .choice(let c)): answers[id] = FakeJev.choice(c, pick: next, conf: conf)
            case ("app", .choice(let c)): answers[id] = FakeJev.choice(c, pick: "notes", conf: 0.95)
            case ("site", .choice(let c)): answers[id] = FakeJev.choice(c, pick: "not_stated", conf: 0.9)
            case ("scroll_amount", .score(let s)): answers[id] = .score(ScoreAnswer(score: 1, probabilities: Dictionary(uniqueKeysWithValues: (0..<s.criteria.count).map { (String($0), $0 == 1 ? 1.0 : 0.0) }), confidence: 0.9))
            case ("text_span", .choice(let c)): answers[id] = FakeJev.choice(c, pick: Questions.spanNone, conf: 0.9)
            case ("click_target", .choice(let c)): answers[id] = FakeJev.choice(c, pick: c.criteria.keys.sorted().first ?? "none", conf: 0.9)
            case ("type_target", .choice(let c)): answers[id] = FakeJev.choice(c, pick: Questions.targetFocused, conf: 0.9)
            default: break
            }
        }
        return JevResponse(model: "fake", answers: answers, usage: Usage(inputTokens: 200, outputTokens: 1), latencyMs: 1, requestId: nil)
    }
}

final class FakeEscalation: Escalating, @unchecked Sendable {
    let name = "fake-writer"
    let writes = OSAllocatedUnfairLock(initialState: 0)
    func plan(goal: String) async throws -> [String] { ["open the notes app (done when: Notes is frontmost)", "create a new note (done when: an empty note is open)"] }
    func write(goal: String, field: FocusedField?, app: String, history: [String]) async throws -> String? { writes.withLock { $0 += 1 }; return "Milk, eggs, bread" }
    func compose(goal: String, observations: [String], history: [String]) async throws -> String? { "It is 42." }
}

@Suite struct TaskRunnerTests {
    func runner(_ jev: FakeGoalJev, perception: FakePerception, escalation: (any Escalating)? = nil, skipIntake: Bool = true) -> (TaskRunner, FakeExecutor) {
        let executor = FakeExecutor(perception: perception)
        var cfg = TaskRunner.Config(); cfg.skipIntake = skipIntake
        return (TaskRunner(decider: jev, perception: perception, executor: executor, escalation: escalation, log: RunLog.discarding(), clock: ManualClock(), config: cfg), executor)
    }

    @Test func chainRunsUntilAchieved() async {
        let jev = FakeGoalJev()
        let (r, exec) = runner(jev, perception: FakePerception())
        let result = await r.run(TaskSpec(goal: "open notes and create a new note"))
        #expect(result.outcome == .achieved)
        #expect(exec.summaries == ["open_app Notes", "new_note"])
        #expect(result.steps.map(\.kind) == [.act, .act, .achieved])
        #expect(result.escalations == 0)
    }

    @Test func blockedScreenStopsTheLoop() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, elements in elements.contains { $0.contains("Sign in") } ? (0.1, 0.92, 0.1, "abstain", 0.9) : (0.05, 0.05, 0.1, "open_app", 0.95) }
        let els = [Element(id: "e01", role: "button", text: "Sign in", where: "center", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 10, height: 10))]
        let (r, exec) = runner(jev, perception: FakePerception(elements: els))
        let result = await r.run(TaskSpec(goal: "open notes"))
        #expect(result.outcome == .blocked)
        #expect(exec.summaries.isEmpty)
        #expect(result.steps.last?.kind == .blocked)
    }

    @Test func stepBudgetEndsAnEndlessGoal() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, _ in (0.1, 0.05, 0.1, "scroll_down", 0.9) }
        let (r, exec) = runner(jev, perception: FakePerception())
        // "keep scrolling ... more" asks for repeats, so the no-repeat rule stands aside and the budget ends it.
        let result = await r.run(TaskSpec(goal: "keep scrolling down more and more", stepBudget: 4))
        #expect(result.outcome == .budgetExhausted)
        #expect(exec.summaries.count == 4)
    }

    @Test func repeatingAVerifiedActionIsNotProgress() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, _ in (0.1, 0.05, 0.1, "scroll_down", 0.9) }
        let (r, exec) = runner(jev, perception: FakePerception())
        let result = await r.run(TaskSpec(goal: "read the whole page", stepBudget: 8))
        #expect(result.outcome == .abstained)
        #expect(exec.summaries.count == 1, "the second identical scroll is refused, then the loop stops")
    }

    @Test func twoAbstainsStop() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, _ in (0.1, 0.05, 0.1, "abstain", 0.9) }
        let (r, exec) = runner(jev, perception: FakePerception())
        let result = await r.run(TaskSpec(goal: "do something impossible"))
        #expect(result.outcome == .abstained)
        #expect(exec.summaries.isEmpty)
        #expect(result.steps.count == 2)
    }

    @Test func reobserveOnlyAfterAnActionAndNeverTwiceInARow() async {
        let jev = FakeGoalJev()
        let looks = OSAllocatedUnfairLock(initialState: 0)
        jev.rule = { app, history, _ in
            // A fresh screen asks to reobserve (ignored: nothing happened yet); after the first
            // action it asks again once (honoured), then a second time (ignored), then acts.
            if history.contains(where: { $0.hasPrefix("new_note") }) { return (0.95, 0.05, 0.1, "abstain", 0.9) }
            if history.isEmpty { return (0.05, 0.05, 0.9, "open_app", 0.95) }
            let n = looks.withLock { $0 += 1; return $0 }
            return n <= 2 ? (0.1, 0.05, 0.9, "new_note", 0.9) : (0.1, 0.05, 0.1, "new_note", 0.9)
        }
        let (r, exec) = runner(jev, perception: FakePerception())
        let result = await r.run(TaskSpec(goal: "open notes and create a new note"))
        #expect(result.outcome == .achieved)
        #expect(result.steps.map(\.kind) == [.act, .reobserve, .act, .achieved])
        #expect(exec.summaries == ["open_app Notes", "new_note"])
    }

    @Test func missingDetailAsksInsteadOfRunning() async {
        let jev = FakeGoalJev()
        jev.missing = "recipient"
        let (r, exec) = runner(jev, perception: FakePerception(), skipIntake: false)
        let result = await r.run(TaskSpec(goal: "send the report"))
        #expect(result.outcome == .needsClarification)
        #expect(result.detail == "Which recipient?")
        #expect(exec.summaries.isEmpty)
    }

    @Test func compoundGoalIsPlannedWithinBudget() async {
        let jev = FakeGoalJev()
        jev.compound = 0.9
        let (r, exec) = runner(jev, perception: FakePerception(), escalation: FakeEscalation(), skipIntake: false)
        let result = await r.run(TaskSpec(goal: "open notes and create a new note"))
        #expect(result.outcome == .achieved)
        #expect(result.task.subgoals.count == 2)
        #expect(result.escalations == 1)
        #expect(exec.summaries == ["open_app Notes", "new_note"])
    }

    @Test func writerFillsTextNoSpanCovers() async {
        let jev = FakeGoalJev()
        jev.rule = { _, history, _ in history.contains(where: { $0.hasPrefix("type_text") }) ? (0.95, 0.05, 0.1, "abstain", 0.9) : (0.1, 0.05, 0.1, "type_text", 0.9) }
        let esc = FakeEscalation()
        let (r, exec) = runner(jev, perception: FakePerception(field: FocusedField(role: "textarea")), escalation: esc)
        let result = await r.run(TaskSpec(goal: "write my grocery list in this note"))
        #expect(result.outcome == .achieved)
        #expect(exec.summaries == ["type_text 'Milk, eggs, bread'"])
        #expect(result.escalations == 1)
        #expect(result.steps.first?.escalation == "fake-writer write (17 chars)")
    }

    @Test func noWriterMeansNoTypingWithoutASpan() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, _ in (0.1, 0.05, 0.1, "type_text", 0.9) }
        let (r, exec) = runner(jev, perception: FakePerception(field: FocusedField(role: "textarea")))
        let result = await r.run(TaskSpec(goal: "write my grocery list in this note"))
        #expect(result.outcome == .abstained)
        #expect(exec.summaries.isEmpty)
    }

    @Test func goalClausesSplitAtStepJoinersAndValueInField() {
        #expect(Questions.goalClauses("open chrome and search google for norbert wiener then open the wikipedia result")
                == ["open chrome", "search google for norbert wiener", "open the wikipedia result"])
        #expect(Questions.goalClauses("make the title say salt and pepper") == ["make the title say salt and pepper"])
        #expect(Questions.goalClauses("make a new note called groceries with milk and eggs as the body") == ["make a new note", "called groceries", "with milk and eggs as the body"])
        #expect(Questions.goalClauses("create a new note titled groceries and write milk and eggs in it") == ["create a new note", "titled groceries", "write milk and eggs in it"])
        #expect(Questions.goalClauses("type Ada in the first name field and Lovelace in the last name field") == ["type Ada in the first name field", "Lovelace in the last name field"])
        #expect(Questions.goalClauses("open notes, then create a new note and then type hello") == ["open notes", "create a new note", "type hello"])
        #expect(Questions.goalClauses("open notes") == ["open notes"])
    }

    @Test func unknownOutcomeIsNeverRepeated() async {
        let jev = FakeGoalJev()
        jev.rule = { _, _, _ in (0.1, 0.05, 0.1, "take_photo", 0.9) }
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        executor.verificationOverride = .unknown
        var cfg = TaskRunner.Config(); cfg.skipIntake = true
        let r = TaskRunner(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: ManualClock(), config: cfg)
        let result = await r.run(TaskSpec(goal: "take a picture"))
        #expect(executor.summaries == ["take_photo"], "one attempt only")
        #expect(result.outcome == .needsClarification)
        #expect(result.detail.contains("could not be verified"))
    }
}
