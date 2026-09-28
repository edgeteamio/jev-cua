import Foundation
import Testing
@testable import JevCore

@Suite struct AnswerValidationTests {
    let questions: [String: Question] = [
        "intent": .choice("Which?", ["open_app": nil, "web_search": nil, "none": nil]),
        "complete": .noul("Done?"),
        "amount": .score("How far?", ["little", "page", "end"]),
    ]

    func response(intent: ChoiceAnswer, complete: Double = 0.7, amount: ScoreAnswer? = nil) -> JevResponse {
        JevResponse(model: "m", answers: [
            "intent": .choice(intent),
            "complete": .noul(complete),
            "amount": .score(amount ?? ScoreAnswer(score: 1.0, probabilities: ["0": 0.2, "1": 0.6, "2": 0.2], confidence: 0.5)),
        ], usage: Usage(inputTokens: 1, outputTokens: 0), latencyMs: 0, requestId: nil)
    }

    let good = ChoiceAnswer(choice: "open_app", probabilities: ["open_app": 0.8, "web_search": 0.15, "none": 0.05], confidence: 0.6)

    @Test func acceptsWellFormedAnswers() throws {
        try response(intent: good).validate(against: questions)
    }

    @Test func rejectsUnknownChoice() {
        let bad = ChoiceAnswer(choice: "quit", probabilities: ["open_app": 0.8, "web_search": 0.15, "none": 0.05], confidence: 0.6)
        #expect(throws: MalformedAnswer.self) { try response(intent: bad).validate(against: questions) }
    }

    @Test func rejectsProbabilityKeysThatDoNotMatchOptions() {
        let missing = ChoiceAnswer(choice: "open_app", probabilities: ["open_app": 0.9, "none": 0.1], confidence: 0.6)
        #expect(throws: MalformedAnswer.self) { try response(intent: missing).validate(against: questions) }
        let extra = ChoiceAnswer(choice: "open_app", probabilities: ["open_app": 0.8, "web_search": 0.1, "none": 0.05, "quit": 0.05], confidence: 0.6)
        #expect(throws: MalformedAnswer.self) { try response(intent: extra).validate(against: questions) }
    }

    @Test func rejectsProbabilitiesThatDoNotSumToOne() {
        let bad = ChoiceAnswer(choice: "open_app", probabilities: ["open_app": 0.8, "web_search": 0.5, "none": 0.05], confidence: 0.6)
        #expect(throws: MalformedAnswer.self) { try response(intent: bad).validate(against: questions) }
    }

    @Test func rejectsChoiceThatIsNotTheArgmax() {
        let bad = ChoiceAnswer(choice: "none", probabilities: ["open_app": 0.8, "web_search": 0.15, "none": 0.05], confidence: 0.6)
        #expect(throws: MalformedAnswer.self) { try response(intent: bad).validate(against: questions) }
        // Just past the tolerance still fails: 0.47 against 0.50.
        let clear = ChoiceAnswer(choice: "none", probabilities: ["open_app": 0.03, "web_search": 0.50, "none": 0.47], confidence: 0.4)
        #expect(throws: MalformedAnswer.self) { try response(intent: clear).validate(against: questions) }
    }

    /// #18: 'none' 0.43 against 'type_text' 0.44 made the whole response unusable, and with it a
    /// follow-up answer that was fine. A near-tie within the sum tolerance is the model's call.
    @Test func acceptsANearTieAsTheModelsOwnChoice() throws {
        let nearTie = ChoiceAnswer(choice: "none", probabilities: ["open_app": 0.13, "web_search": 0.44, "none": 0.43], confidence: 0.39)
        try response(intent: nearTie).validate(against: questions)
    }

    @Test func rejectsOutOfRangeNoulAndScoreKeys() {
        #expect(throws: MalformedAnswer.self) { try response(intent: good, complete: 1.4).validate(against: questions) }
        let badScore = ScoreAnswer(score: 1.0, probabilities: ["0": 0.5, "7": 0.5], confidence: 0.5)
        #expect(throws: MalformedAnswer.self) { try response(intent: good, amount: badScore).validate(against: questions) }
    }

    @Test func rejectsMissingAndMistypedAnswers() {
        let missing = JevResponse(model: "m", answers: ["intent": .choice(good)], usage: Usage(inputTokens: 1, outputTokens: 0), latencyMs: 0, requestId: nil)
        #expect(throws: MalformedAnswer.self) { try missing.validate(against: questions) }
        let mistyped = JevResponse(model: "m", answers: ["intent": .noul(0.5), "complete": .noul(0.5), "amount": .noul(0.5)],
                                   usage: Usage(inputTokens: 1, outputTokens: 0), latencyMs: 0, requestId: nil)
        #expect(throws: MalformedAnswer.self) { try mistyped.validate(against: questions) }
    }
}
