import Testing
@testable import JevMac

@Suite struct SpeechStatsTests {
    @Test func computesCadenceRevisionsAndLatencies() {
        // Speech from t=1.0 to t=1.8, first text at 1.25, final at 2.3.
        let levels: [AudioLevel] = stride(from: 0.0, through: 3.0, by: 0.05).map {
            AudioLevel(at: $0, rms: ($0 >= 1.0 && $0 <= 1.8) ? 0.1 : 0.001)
        }
        let samples: [SpeechProbeSample] = [
            .init(at: 1.25, text: "open", isFinal: false, segment: 0),
            .init(at: 1.45, text: "open the", isFinal: false, segment: 0),
            .init(at: 1.65, text: "open notes", isFinal: false, segment: 0),   // revision: not a prefix extension
            .init(at: 1.85, text: "open notes app", isFinal: false, segment: 0),
            .init(at: 2.30, text: "open notes app", isFinal: true, segment: 1),
        ]
        let s = SpeechStats.compute(samples: samples, levels: levels, threshold: 0.01)
        #expect(s.events == 5)
        #expect(s.finals == 1)
        #expect(s.revisions == 1)
        #expect(abs((s.interEventMsP50 ?? 0) - 200) < 0.001)
        // onset 1.0 -> first text 1.25
        #expect(abs((s.onsetToFirstTextMsP50 ?? 0) - 250) < 1)
        // last loud sample at 1.8 -> final 2.3
        #expect(abs((s.speechEndToFinalMsP50 ?? 0) - 500) < 1)
    }

    @Test func emptyInputYieldsNils() {
        let s = SpeechStats.compute(samples: [], levels: [], threshold: 0.01)
        #expect(s.events == 0)
        #expect(s.interEventMsP50 == nil)
        #expect(s.onsetToFirstTextMsP50 == nil)
    }

    @Test func percentile() {
        #expect(SpeechStats.percentile([5, 1, 3], 0.5) == 3)
        #expect(SpeechStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 9)
        #expect(SpeechStats.percentile([], 0.5) == nil)
    }
}
