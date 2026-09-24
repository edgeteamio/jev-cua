import Foundation
import JevCore

/// One recorded transcript event from a probe run.
public struct SpeechProbeSample: Sendable, Codable, Equatable {
    public let at: TimeInterval
    public let text: String
    public let isFinal: Bool
    public let segment: Int
    public init(at: TimeInterval, text: String, isFinal: Bool, segment: Int) {
        self.at = at; self.text = text; self.isFinal = isFinal; self.segment = segment
    }
}

/// Cadence numbers Phase 0 needs to pick the primary recognizer.
public struct SpeechProbeStats: Sendable, Codable, Equatable {
    public var events: Int
    public var finals: Int
    /// Transcript events whose text did not extend the previous text (a rewrite).
    public var revisions: Int
    public var interEventMsP50: Double?
    public var interEventMsP90: Double?
    /// Speech onset (audio above threshold) to the first non-empty text in that segment.
    public var onsetToFirstTextMsP50: Double?
    /// Last audio above threshold before a final to that final.
    public var speechEndToFinalMsP50: Double?
    public var speechEndToFinalMsP90: Double?
}

public enum SpeechStats {
    public static func compute(samples: [SpeechProbeSample], levels: [AudioLevel], threshold: Float) -> SpeechProbeStats {
        var stats = SpeechProbeStats(events: samples.count, finals: samples.filter(\.isFinal).count, revisions: 0)
        let transcripts = samples.filter { !$0.isFinal }

        // Inter-event cadence over volatile events only.
        let gaps = zip(transcripts.dropFirst(), transcripts).map { ($0.at - $1.at) * 1000 }
        stats.interEventMsP50 = percentile(gaps, 0.5)
        stats.interEventMsP90 = percentile(gaps, 0.9)

        // Revisions: text that is not an extension of the previous volatile text in the same segment.
        var prev: (segment: Int, text: String)? = nil
        for s in transcripts {
            if let p = prev, p.segment == s.segment, !s.text.hasPrefix(p.text) { stats.revisions += 1 }
            prev = (s.segment, s.text)
        }

        // Onset to first text, per segment.
        let loud = levels.filter { $0.rms > threshold }.map(\.at)
        var onsetLatencies: [Double] = []
        var endLatencies: [Double] = []
        var segmentStart: TimeInterval = levels.first?.at ?? samples.first?.at ?? 0
        var seenSegments = Set<Int>()
        for s in samples {
            if !s.isFinal, !seenSegments.contains(s.segment), !s.text.isEmpty {
                seenSegments.insert(s.segment)
                if let onset = loud.first(where: { $0 >= segmentStart && $0 <= s.at }) {
                    onsetLatencies.append((s.at - onset) * 1000)
                }
            }
            if s.isFinal {
                if let lastLoud = loud.last(where: { $0 <= s.at && $0 >= segmentStart }) {
                    endLatencies.append((s.at - lastLoud) * 1000)
                }
                segmentStart = s.at
            }
        }
        stats.onsetToFirstTextMsP50 = percentile(onsetLatencies, 0.5)
        stats.speechEndToFinalMsP50 = percentile(endLatencies, 0.5)
        stats.speechEndToFinalMsP90 = percentile(endLatencies, 0.9)
        return stats
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    public static func markdownRow(provider: String, _ s: SpeechProbeStats) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "n/a" }
        return "| \(provider) | \(s.events) | \(s.finals) | \(s.revisions) | \(f(s.interEventMsP50)) | \(f(s.interEventMsP90)) | \(f(s.onsetToFirstTextMsP50)) | \(f(s.speechEndToFinalMsP50)) | \(f(s.speechEndToFinalMsP90)) |"
    }

    public static let markdownHeader = """
    | provider | events | finals | revisions | gap p50 ms | gap p90 ms | onset→text p50 ms | end→final p50 ms | end→final p90 ms |
    |---|---|---|---|---|---|---|---|---|
    """
}
