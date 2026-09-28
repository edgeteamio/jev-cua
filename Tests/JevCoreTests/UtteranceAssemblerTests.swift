import Foundation
import JevCore
import Testing

@Suite struct UtteranceAssemblerTests {
    @Test func chunkedFinalsStayOneUtteranceAndFinalWaitsForQuiet() {
        var a = UtteranceAssembler(gapMs: 1500, finalQuietMs: 400)
        let r1 = a.apply(segmentText: "google search", isFinal: false, at: 1.0)
        #expect(r1 == TranscriptRevision(utteranceId: "u0", text: "google search", isFinal: false, at: 1.0))
        // A final chunk mid-command is NOT reported as final.
        let r2 = a.apply(segmentText: "google search norbert", isFinal: true, at: 1.4)
        #expect(r2?.text == "google search norbert" && r2?.isFinal == false)
        #expect(a.pendingFinal(now: 1.5) == nil, "not quiet yet")
        // The recognizer keeps going: a new volatile tail after the mid-command final.
        let r3 = a.apply(segmentText: "wiener", isFinal: false, at: 1.6)
        #expect(r3 == TranscriptRevision(utteranceId: "u0", text: "google search norbert wiener", isFinal: false, at: 1.6))
        #expect(a.pendingFinal(now: 3.0) == nil, "a volatile tail is never final")
        #expect(!a.shouldClose(now: 3.0))
        let r4 = a.apply(segmentText: "wiener", isFinal: true, at: 1.9)
        #expect(r4 == nil, "finalizing the same words changes nothing yet")
        #expect(a.pendingFinal(now: 2.1) == nil, "only 200 ms quiet")
        let f = a.pendingFinal(now: 2.4)
        #expect(f == TranscriptRevision(utteranceId: "u0", text: "google search norbert wiener", isFinal: true, at: 2.4))
        #expect(a.pendingFinal(now: 2.5) == nil, "sent once")
        #expect(!a.shouldClose(now: 2.5))
        #expect(a.shouldClose(now: 3.5))
        #expect(a.close() == "google search norbert wiener")
        #expect(a.utteranceId == "u1" && a.text.isEmpty)
    }

    @Test func micActivityDelaysTheFinalAndTheBoundary() {
        var a = UtteranceAssembler(gapMs: 1000, finalQuietMs: 400)
        _ = a.apply(segmentText: "open notes", isFinal: true, at: 1.0)
        a.noteLoud(at: 1.3)
        #expect(a.pendingFinal(now: 1.5) == nil, "the user was still making noise at 1.3")
        #expect(a.pendingFinal(now: 1.75) != nil)
        a.noteLoud(at: 2.4)
        #expect(!a.shouldClose(now: 3.0), "the user was still talking at 2.4")
        #expect(a.shouldClose(now: 3.5))
    }

    @Test func unchangedEventsProduceNoRevision() {
        var a = UtteranceAssembler()
        #expect(a.apply(segmentText: "open", isFinal: false, at: 1) != nil)
        #expect(a.apply(segmentText: "open", isFinal: false, at: 1.1) == nil)
        #expect(a.apply(segmentText: "", isFinal: true, at: 1.2) == nil, "empty final of nothing new")
        #expect(a.apply(segmentText: "", isFinal: false, at: 1.3) == nil)
        #expect(a.text.isEmpty)
    }

    @Test func emptyUtteranceNeverClosesOrFinalizes() {
        var a = UtteranceAssembler()
        #expect(!a.shouldClose(now: 100))
        #expect(a.pendingFinal(now: 100) == nil)
        #expect(a.releaseFinal(at: 100) == nil)
    }

    /// Hold-to-talk (item 3c): releasing the key makes everything said final at once, the
    /// volatile tail included, and only once.
    @Test func releasingAHoldSendsEverythingAsFinalOnce() {
        var a = UtteranceAssembler()
        _ = a.apply(segmentText: "google the", isFinal: true, at: 0)
        _ = a.apply(segmentText: "minnesota vikings", isFinal: false, at: 0.2)
        let f = a.releaseFinal(at: 0.3)
        #expect(f?.text == "google the minnesota vikings")
        #expect(f?.isFinal == true)
        #expect(a.releaseFinal(at: 0.4) == nil, "sent once")
        _ = a.apply(segmentText: "minnesota vikings", isFinal: true, at: 0.5)
        #expect(a.pendingFinal(now: 5) == nil, "the recognizer's own final of the same words is not a second one")
    }
}
