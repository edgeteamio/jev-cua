import Foundation
import Testing
@testable import JevCore

/// The lab's follow-up support (#18): a fixture's last action makes the `followup` head be asked,
/// a follow-up act is scored by what it ran, and chatter in the same scene is a false fire if typed.
@Suite struct LabTests {
    @Test func aFollowupFixtureAsksTheFollowupHeadAndScoresWhatItRan() async throws {
        let json = """
        {"commands": [{"text": "milk and eggs", "intent": "type_text", "altIntents": ["none"], "expectedActs": ["type_text"], "span": "milk and eggs",
                       "frontmostApp": "Notes", "focusedField": {"role": "textarea", "valuePreview": "groceries\\n", "secure": false},
                       "lastAction": {"pressEnter": {}}}],
         "nonCommands": [{"text": "i think we should get lunch", "focusedField": {"role": "textarea", "secure": false},
                          "lastAction": {"pressEnter": {}}}]}
        """
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(json.utf8))
        let report = try await LabRunner(decider: FakeJev()).run(fixtures, name: "followups")
        let c = report.commands[0]
        #expect(c.rows.last?.followup == "supplies_text")
        #expect(c.acts == ["type_text"], "scored by the action the follow-up ran, not the intent head")
        #expect(c.actsCorrect)
        #expect(c.finalSpanCorrect == true)
        #expect(c.prematureActs.isEmpty, "a follow-up waits for the phrase to end")
        #expect(report.nonCommands[0].rows.last?.followup == "unrelated")
        #expect(report.nonCommands[0].falseFires.isEmpty)
    }

    @Test func fixturesWithoutASceneAreUnchanged() async throws {
        let fixtures = Fixtures(commands: [FixtureCommand(text: "open chrome", intent: "open_app", app: "chrome")], nonCommands: [])
        let report = try await LabRunner(decider: FakeJev()).run(fixtures, name: "plain")
        #expect(report.commands[0].rows.allSatisfy { $0.followup == nil }, "no last action, no followup head")
        #expect(report.commands[0].acts == ["open_app"])
    }
}
