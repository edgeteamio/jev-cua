import Foundation
import Testing
@testable import JevCore

@Suite struct JevTypesTests {
    @Test func encodesRequestInApiShape() throws {
        let req = JevRequest(
            state: ["transcript": "open notes"],
            model: "jev-1.13.0",
            questions: [
                "intent": .choice("Which action?", ["open_app": ["what": "Open an app"], "none": nil]),
                "complete": .noul("Is the command complete?", true: "yes", false: "no"),
                "amount": .score("How far?", ["a little", "a page"]),
            ]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = try JSONSerialization.jsonObject(with: enc.encode(req)) as! [String: Any]

        #expect(json["model"] as? String == "jev-1.13.0")
        let questions = json["questions"] as! [String: [String: Any]]
        #expect(questions["intent"]?["type"] as? String == "choice")
        let criteria = questions["intent"]?["criteria"] as! [String: Any]
        #expect(criteria["none"] is NSNull)
        #expect((criteria["open_app"] as? [String: Any])?["what"] as? String == "Open an app")
        let noul = questions["complete"]!
        #expect(noul["type"] as? String == "noul")
        #expect((noul["criteria"] as? [String: Any])?["true"] as? String == "yes")
        let score = questions["amount"]!
        #expect((score["criteria"] as? [Any])?.count == 2)
    }

    @Test func decodesDocumentedResponse() throws {
        // Response body from docs.typesafe.ai/introduction/quickstart, plus a probabilities map on the score.
        let body = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "department": {"type": "choice", "choice": "billing",
                           "probabilities": {"billing": 0.84, "technical": 0.159, "sales": 0.001}, "confidence": 0.596},
            "frustration": {"type": "score", "score": 1.035,
                            "legend": {"0": "Calm", "1": "Frustrated", "2": "Angry"},
                            "probabilities": {"0": 0.1, "1": 0.765, "2": 0.135}, "confidence": 0.842},
            "is_urgent": {"type": "noul", "noul": 0.999}
          },
          "usage": {"input_tokens": 312, "output_tokens": 48}
        }
        """
        let resp = try JSONDecoder().decode(JevResponse.self, from: Data(body.utf8))
        #expect(resp.model == "jev-1.13.0")
        #expect(resp.answers["is_urgent"]?.noul == 0.999)
        let dept = try #require(resp.answers["department"]?.choice)
        #expect(dept.choice == "billing")
        #expect(dept.confidence == 0.596)
        #expect(dept.ranked().first?.id == "billing")
        #expect(dept.ranked(excluding: ["billing"]).first?.id == "technical")
        let score = try #require(resp.answers["frustration"]?.score)
        #expect(score.score == 1.035)
        #expect(score.legend?["1"]?.stringValue == "Frustrated")
        #expect(resp.usage.inputTokens == 312)
        #expect(abs(resp.usage.costUSD - 312.0 / 1_000_000 * 0.042) < 1e-12)
    }

    @Test func rejectsUnknownAnswerType() {
        let body = #"{"model":"m","answers":{"x":{"type":"text","text":"hi"}},"usage":{"input_tokens":1,"output_tokens":0}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JevResponse.self, from: Data(body.utf8))
        }
    }

    @Test func answersRoundTrip() throws {
        let answers: [String: Answer] = [
            "a": .noul(0.25),
            "b": .choice(ChoiceAnswer(choice: "x", probabilities: ["x": 0.7, "y": 0.3], confidence: 0.4)),
            "c": .score(ScoreAnswer(score: 1.5, legend: ["0": "lo", "1": "hi"], probabilities: ["0": 0.5, "1": 0.5], confidence: 0.1)),
        ]
        let data = try JSONEncoder().encode(answers)
        let back = try JSONDecoder().decode([String: Answer].self, from: data)
        #expect(back == answers)
    }

    @Test func cacheKeyDependsOnModelAndQuestions() {
        let a = JevRequest(state: "x", model: "jev-1.13.0", questions: ["q": .noul("Is it?")])
        let b = JevRequest(state: "x", model: "jev-1.14.0", questions: ["q": .noul("Is it?")])
        let c = JevRequest(state: "x", model: "jev-1.13.0", questions: ["q": .noul("Is it really?")])
        #expect(a.cacheKey() == JevRequest(state: "x", model: "jev-1.13.0", questions: ["q": .noul("Is it?")]).cacheKey())
        #expect(a.cacheKey() != b.cacheKey())
        #expect(a.cacheKey() != c.cacheKey())
    }

    @Test func contractsRoundTrip() throws {
        let action = Action.webSearch(url: "https://www.google.com/search?q=norbert%20wiener", query: "norbert wiener", site: "google")
        let cand = Candidate(id: "c1", snapshotId: "s1", action: action, payload: "norbert wiener", expectedPostcondition: "url contains query")
        let decision = Decision(snapshotId: "s1", candidateSetId: "cs1", utteranceId: "u1", revision: 3, intentEpoch: 0,
                                outcome: .act(candidateId: "c1"), answers: ["intent": .noul(0.9)],
                                reasons: [GateReason(name: "is_command", value: "0.9", threshold: "0.5", pass: true, note: "")],
                                model: "jev-1.13.0", latencyMs: 210, usage: Usage(inputTokens: 900, outputTokens: 12), requestId: "r")
        let data = try JSONEncoder().encode(decision)
        let back = try JSONDecoder().decode(Decision.self, from: data)
        #expect(back == decision)
        #expect(cand.tier == .low)
        #expect(action.kind == "web_search")
        #expect(Action.clickElement(elementId: "e01").tier == .gated)
        #expect(Action.typeText(text: "hello").tier == .medium)
        #expect(Action.scroll(direction: .up, amount: .page).kind == "scroll_up")
    }
}

@Suite struct ModelCardTests {
    @Test func decodesSnakeCaseReleaseDate() throws {
        let body = #"{"models":[{"name":"jev-latest","description":"latest","release_date":"2026-09-15"},{"name":"jev-preview","description":"p"}]}"#
        struct W: Decodable { let models: [ModelCard] }
        let w = try JSONDecoder().decode(W.self, from: Data(body.utf8))
        #expect(w.models[0].releaseDate == "2026-09-15")
        #expect(w.models[1].releaseDate == nil)
    }
    @Test func menuItemActionAndRepeatsRoundTrip() throws {
        let c = Candidate(id: "c1", snapshotId: "s1", action: .menuItem(id: "m03", path: "File › Close Window"),
                          targetElementId: "m03", expectedPostcondition: "ran", repeats: 1)
        let back = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(c))
        #expect(back.action == .menuItem(id: "m03", path: "File › Close Window"))
        #expect(back.summary == "menu_item 'File › Close Window'")
        // A pre-`repeats` candidate JSON still decodes (repeats defaults to 1).
        let legacy = #"{"id":"c2","snapshotId":"s","action":{"scroll":{"direction":"down","amount":"page"}},"tier":"low","preconditions":[],"expectedPostcondition":"x"}"#
        let d = try JSONDecoder().decode(Candidate.self, from: Data(legacy.utf8))
        #expect(d.repeats == 1)
        var counted = c; counted.repeats = 3; counted.action = .scroll(direction: .down, amount: .page)
        #expect(counted.summary == "scroll_down page ×3")
    }

    /// Item 3b: an outage (network, timeout, 5xx, overload, key) shows until Jev answers again; a
    /// bad answer or a cancellation is not one.
    @Test func outagesAreToldApartFromBadAnswers() {
        let timeout = JevError.transport("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"")
        #expect(timeout.isOutage)
        #expect(timeout.outageSummary == "timed out")
        #expect(JevError.transport("The Internet connection appears to be offline.").outageSummary == "no connection")
        #expect(JevError.http(status: 503, body: "").isOutage)
        #expect(JevError.http(status: 401, body: "").outageSummary == "API key rejected (HTTP 401)")
        #expect(JevError.overloaded(retryAfterMs: nil).isOutage)
        #expect(!JevError.http(status: 400, body: "").isOutage)
        #expect(!JevError.decoding("x").isOutage)
        #expect(!JevError.cancelled.isOutage)
    }
}
