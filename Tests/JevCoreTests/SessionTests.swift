import Foundation
import Testing
@testable import JevCore

struct Scenario: Decodable {
    struct Step: Decodable {
        var rev: [JSONValue]?
        var tick: Double?
    }
    struct Expect: Decodable {
        var actions: [String]
        var firstActAfterRevision: Int?
        var pendingAfter: String?
        var noDuplicates: Bool?
        var allVerified: Bool?
    }
    var name: String
    var field: FocusedField?
    var elements: [Element]?
    var steps: [Step]
    var expect: Expect
}

struct Scenarios: Decodable { var scenarios: [Scenario] }

@Suite struct SessionReplayTests {
    static func load() throws -> [Scenario] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/transcripts/scenarios.json")
        return try JSONDecoder().decode(Scenarios.self, from: Data(contentsOf: url)).scenarios
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var events: [SessionEvent] = []
        func add(_ e: SessionEvent) { lock.lock(); events.append(e); lock.unlock() }
        var all: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    @Test(arguments: try load())
    func replay(_ s: Scenario) async throws {
        let clock = ManualClock()
        let perception = FakePerception(field: s.field, elements: s.elements ?? [])
        let executor = FakeExecutor(perception: perception)
        let collector = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(),
                                     clock: clock, onEvent: { collector.add($0) })
        var revisionIndex = -1
        var firstActAfter: Int? = nil
        for step in s.steps {
            if let rev = step.rev {
                revisionIndex += 1
                clock.advance(ms: 200)
                await session.handleTranscript(TranscriptRevision(utteranceId: rev[0].stringValue!, text: rev[1].stringValue!, isFinal: rev[2].boolValue!, at: clock.now()))
                // Let the throttle task run (sleeps are instant on the manual clock).
                for _ in 0..<5 { await Task.yield() }
                await drain(session)
            } else if let ms = step.tick {
                clock.advance(ms: ms)
                await session.tick()
                await drain(session)
            }
            if firstActAfter == nil, !executor.summaries.isEmpty { firstActAfter = revisionIndex }
        }
        #expect(executor.summaries == s.expect.actions, "actions for '\(s.name)'")
        if let f = s.expect.firstActAfterRevision { #expect(firstActAfter == f, "first act revision for '\(s.name)'") }
        if s.expect.pendingAfter != nil || s.steps.contains(where: { ($0.rev?[1].stringValue ?? "").contains("send") }) {
            let pending = await session.pendingCandidate
            #expect(pending?.action.kind == s.expect.pendingAfter, "pending for '\(s.name)'")
        }
        let ledger = await session.ledger
        let keys = ledger.map { "\($0.utteranceId)#\($0.candidateId)" }
        #expect(Set(keys).count == keys.count, "duplicate dispatch in '\(s.name)'")
        if s.expect.allVerified == true {
            #expect(ledger.allSatisfy { $0.status == .acknowledged }, "stale execution in '\(s.name)'")
        }
    }

    /// Wait until the session has nothing in flight, scheduled, or executing (bounded).
    func drain(_ session: CommandSession) async {
        for _ in 0..<200 {
            await Task.yield()
            if await session.isIdle { for _ in 0..<3 { await Task.yield() }; if await session.isIdle { return } }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func confidentClickPressesTheNamedElement() async {
        let clock = ManualClock()
        let els = [Element(id: "e01", role: "button", text: "Take Photo", where: "bottom-center", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 10, height: 10)),
                   Element(id: "e02", role: "button", text: "Effects", where: "bottom-right", editable: false, secure: false, frame: Frame(x: 20, y: 0, width: 10, height: 10))]
        let perception = FakePerception(elements: els)
        let executor = FakeExecutor(perception: perception)
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(), clock: clock)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "click take photo", isFinal: true, at: 0))
        await drain(session)
        #expect(executor.summaries == ["click_element e01"])
    }

    @Test func ambiguousClickShowsBadgesAndASpokenNumberPicks() async {
        let clock = ManualClock()
        let els = [Element(id: "e01", role: "button", text: "Share Note", where: "top-left", editable: false, secure: false, frame: Frame(x: 0, y: 0, width: 10, height: 10)),
                   Element(id: "e02", role: "button", text: "Share Folder", where: "top-right", editable: false, secure: false, frame: Frame(x: 20, y: 0, width: 10, height: 10))]
        let perception = FakePerception(elements: els)
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev()
        let collector = Collector()
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { collector.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "click share", isFinal: true, at: 0))
        await drain(session)
        #expect(executor.summaries.isEmpty, "ambiguous: nothing pressed yet")
        let badges = collector.all.compactMap { e -> [Element]? in if case .disambiguation(let x) = e, let x { return x } else { return nil } }
        #expect(badges.first?.map(\.id) == ["e01", "e02"])
        let callsBefore = jev.calls.withLock { $0.count }
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "the second one", isFinal: true, at: 1))
        await drain(session)
        #expect(executor.summaries == ["click_element e02"])
        #expect(jev.calls.withLock { $0.count } == callsBefore, "a spoken number resolves in code, no model call")
        #expect(badges.count >= 1)
        let cleared = collector.all.contains { if case .disambiguation(nil) = $0 { return true } else { return false } }
        #expect(cleared, "badges cleared after the pick")
    }

    @Test func replayReproducesLoggedDecisions() async throws {
        let clock = ManualClock()
        let perception = FakePerception(field: FocusedField(role: "textarea"))
        let executor = FakeExecutor(perception: perception)
        let root = FileManager.default.temporaryDirectory.appending(path: "jev-cua-replay-\(UUID().uuidString)")
        let log = try RunLog(runsRoot: root, redact: false)
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: log, clock: clock)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open the notes app and create a new note", isFinal: true, at: 0))
        await drain(session)
        log.close()
        #expect(executor.summaries == ["open_app Notes", "new_note"])
        let report = try Replay.run(directory: log.directory)
        #expect(report.rows.count >= 2)
        #expect(report.changed == 0)
        #expect(report.rows.map(\.newCandidate).compactMap { $0 } == ["open_app Notes", "new_note"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func killPhraseCancelsAnInFlightDecision() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev(delayMs: 200)
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "take a picture of me", isFinal: true, at: 0))
        try? await Task.sleep(for: .milliseconds(30))
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "stop", isFinal: true, at: 0.1))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(executor.summaries.isEmpty)
    }

    @Test func supersededPartialMayFireAllowlistedButNotFreeText() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev(delayMs: 120)
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock)

        // Allowlisted: "open the notes" is in flight when "open the notes app" (final) arrives.
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open the notes", isFinal: false, at: 0))
        try? await Task.sleep(for: .milliseconds(30))
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open the notes app", isFinal: true, at: 0.03))
        try? await Task.sleep(for: .milliseconds(500))
        #expect(executor.summaries == ["open_app Notes"])

        // Free text: "google search norbert" in flight when the final arrives; the superseded
        // decision must not act, the rerun on the final must act once with the full query.
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "google search norbert", isFinal: false, at: 1))
        try? await Task.sleep(for: .milliseconds(30))
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "google search norbert wiener", isFinal: true, at: 1.03))
        try? await Task.sleep(for: .milliseconds(600))
        #expect(executor.summaries == ["open_app Notes", "web_search google 'norbert wiener'"])
    }

    @Test func jevErrorProducesNoActionAndNoCrash() async {
        struct Failing: JevDeciding {
            func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse { throw JevError.http(status: 500, body: "boom") }
        }
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let session = CommandSession(decider: Failing(), perception: perception, executor: executor, log: RunLog.discarding(), clock: ManualClock())
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open chrome", isFinal: true, at: 0))
        for _ in 0..<20 { _ = await session.pendingCandidate; await Task.yield() }
        #expect(executor.summaries.isEmpty)
    }
}
