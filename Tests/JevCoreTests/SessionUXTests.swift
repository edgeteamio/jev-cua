import Foundation
import os
import Testing
@testable import JevCore

/// The voice-loop UX pass (review 2026-09-28): armed decisions, lapsing confirmations, "what can I
/// say?", outage reporting, and undo, driven through the real session with fakes.
@Suite struct SessionUXTests {
    typealias Collector = SessionReplayTests.Collector

    func drain(_ session: CommandSession) async {
        for _ in 0..<200 {
            await Task.yield()
            if await session.isIdle { for _ in 0..<3 { await Task.yield() }; if await session.isIdle { return } }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func armed(_ events: [SessionEvent]) -> [Candidate?] {
        events.compactMap { if case .armed(let c) = $0 { return .some(c) } else { return nil } }
    }

    /// Item 1b: a search that waits only for the words to stop is armed, shown, and fired on the
    /// tick that crosses its commit window, on the answers already in hand.
    @Test func armedSearchFiresWhenTheWordsStopWithoutAskingJevAgain() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev()
        let events = Collector()
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "google search norbert wiener", isFinal: false, at: clock.now()))
        await drain(session)
        #expect(executor.summaries.isEmpty, "free text waits for the words to stop")
        #expect(armed(events.all).last??.action.summary == "web_search google 'norbert wiener'", "the ghost chip shows what will run")
        let callsWhenArmed = jev.calls.withLock { $0.count }
        // Whatever the commit window is, the tick that crosses it fires.
        for _ in 0..<30 where executor.summaries.isEmpty {
            clock.advance(ms: 100)
            await session.tick()
            await drain(session)
        }
        #expect(executor.summaries == ["web_search google 'norbert wiener'"])
        #expect(jev.calls.withLock { $0.count } == callsWhenArmed, "no second model call for the same words")
    }

    /// New words disarm nothing by themselves, but the armed decision fires only for the words it
    /// was made on; the next decision re-arms with the longer query.
    @Test func newWordsReplaceTheArmedQuery() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let events = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "google search norbert", isFinal: false, at: clock.now()))
        await drain(session)
        clock.advance(ms: 200)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "google search norbert wiener", isFinal: false, at: clock.now()))
        await drain(session)
        for _ in 0..<30 where executor.summaries.isEmpty {
            clock.advance(ms: 100)
            await session.tick()
            await drain(session)
        }
        #expect(executor.summaries == ["web_search google 'norbert wiener'"], "the whole query, once")
        #expect(armed(events.all).compactMap { $0?.action.summary } == ["web_search google 'norbert'", "web_search google 'norbert wiener'"])
    }

    @Test func theGhostChipClearsWhenTheUtteranceEnds() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let events = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: FakeExecutor(perception: perception), log: RunLog.discarding(),
                                     clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "google search norbert wiener", isFinal: false, at: clock.now()))
        await drain(session)
        await session.endUtterance(reason: "paused")
        #expect(events.all.last == .armed(nil))
    }

    /// Item 2c: before this, a pending confirmation never lapsed.
    @Test func anUnansweredConfirmationLapses() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let events = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "send it press enter", isFinal: true, at: clock.now()))
        await drain(session)
        #expect(await session.pendingCandidate?.action.kind == "press_enter")
        clock.advance(ms: Double(Config.candidateTtlMs) - 500)
        await session.tick()
        #expect(await session.pendingCandidate != nil, "still inside the window")
        clock.advance(ms: 600)
        await session.tick()
        #expect(await session.pendingCandidate == nil, "lapsed")
        #expect(events.all.contains(.notice("confirmation lapsed: Return")))
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "confirm", isFinal: true, at: clock.now()))
        await drain(session)
        #expect(executor.summaries.isEmpty, "a late confirm runs nothing")
    }

    /// Item 3d: answered in code, with the front app's examples, and no model call.
    @Test func whatCanISayShowsTheFrontAppsExamples() async {
        let clock = ManualClock()
        let perception = FakePerception(app: AppIdentity(name: "Notes", bundleId: "com.apple.Notes", pid: 3))
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev()
        let events = Collector()
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        // A partial waits for the phrase to end: it could still grow into something else.
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "what can I say", isFinal: false, at: clock.now()))
        await drain(session)
        #expect(!events.all.contains { if case .help = $0 { true } else { false } })
        clock.advance(ms: Double(Config.payloadSilenceMs) + 50)
        await session.tick()
        await drain(session)
        let help = events.all.compactMap { if case .help(let p) = $0 { p } else { nil } }
        #expect(help.first?.first == "create a new note")
        #expect(jev.calls.withLock { $0.count } == 0)
        #expect(executor.summaries.isEmpty)
    }

    /// Item 3b: an outage is reported once when it starts and once when Jev answers again; a
    /// malformed answer is not an outage.
    @Test func anOutageShowsOnceAndClearsOnTheNextAnswer() async {
        final class Flaky: JevDeciding, @unchecked Sendable {
            let failing = OSAllocatedUnfairLock(initialState: true)
            let inner = FakeJev()
            func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse {
                if failing.withLock({ $0 }) { throw JevError.transport("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"") }
                return try await inner.systemOne(state: state, questions: questions, model: model)
            }
        }
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let jev = Flaky()
        let events = Collector()
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open chrome", isFinal: true, at: clock.now()))
        await drain(session)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "open safari", isFinal: true, at: clock.now()))
        await drain(session)
        jev.failing.withLock { $0 = false }
        await session.handleTranscript(TranscriptRevision(utteranceId: "u3", text: "open chrome", isFinal: true, at: clock.now()))
        await drain(session)
        let outages = events.all.compactMap { if case .offline(let why) = $0 { Optional(why) } else { nil } }
        #expect(outages == ["timed out", nil], "one report when it starts, one when it ends")
        #expect(!events.all.contains { if case .error = $0 { true } else { false } }, "an outage is not shown as an error")
        #expect(executor.summaries == ["open_app Google Chrome"])
    }

    /// Item 3d: Undo reverses the newest action only when a safe inverse exists.
    @Test func undoGoesBackAfterAnInPlaceSearchAndUndoesTyping() async {
        let clock = ManualClock()
        let perception = FakePerception(field: FocusedField(role: "textarea"))
        let executor = FakeExecutor(perception: perception)
        executor.detailFor = { action in if case .webSearch = action { Undo.navigatedInPlace } else { "ok" } }
        let events = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "google search norbert wiener", isFinal: true, at: clock.now()))
        await drain(session)
        await session.undoLast()
        #expect(executor.summaries == ["web_search google 'norbert wiener'", "go_back"])
        await session.undoLast()
        #expect(events.all.last == .notice("nothing to undo"), "an undo is not itself undone")
        await session.handleTranscript(TranscriptRevision(utteranceId: "u2", text: "type hello", isFinal: true, at: clock.now()))
        await drain(session)
        await session.undoLast()
        #expect(executor.summaries.last == "menu_item 'Edit › Undo'")
    }

    /// Found by the 2026-09-28 sessions run on a locked Mac: a Return reached the lock screen.
    @Test func nothingIsDecidedOrRunWhileTheScreenIsLocked() async {
        let clock = ManualClock()
        let perception = FakePerception(app: AppIdentity(name: "loginwindow", bundleId: Config.lockScreenBundleId, pid: 4))
        let executor = FakeExecutor(perception: perception)
        let jev = FakeJev()
        let session = CommandSession(decider: jev, perception: perception, executor: executor, log: RunLog.discarding(), clock: clock)
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "press enter", isFinal: true, at: clock.now()))
        await drain(session)
        #expect(executor.summaries.isEmpty)
        #expect(jev.calls.withLock { $0.count } == 0, "speech near a locked Mac is not sent to Jev")
    }

    @Test func nothingToUndoAfterAnActionWithoutASafeInverse() async {
        let clock = ManualClock()
        let perception = FakePerception()
        let executor = FakeExecutor(perception: perception)
        let events = Collector()
        let session = CommandSession(decider: FakeJev(), perception: perception, executor: executor, log: RunLog.discarding(), clock: clock, onEvent: { events.add($0) })
        await session.handleTranscript(TranscriptRevision(utteranceId: "u1", text: "open chrome", isFinal: true, at: clock.now()))
        await drain(session)
        await session.undoLast()
        #expect(executor.summaries == ["open_app Google Chrome"], "a launch has no safe inverse")
        #expect(events.all.last == .notice("nothing to undo"))
    }
}
