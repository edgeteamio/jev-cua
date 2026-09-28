import Foundation

/// Turns recognizer chunks into session utterances (plan 9.5, Phase 3).
///
/// Recognizers finalize in chunks, sometimes mid-command, so one utterance is everything said
/// since the last boundary: finalized chunks plus the volatile tail. A boundary happens when
/// the recognizer has finalized everything so far and the microphone has been quiet for
/// `gapMs`, or when the session consumed the whole text and went idle. Pure so it can be tested
/// without audio; VoiceLoop drives it.
public struct UtteranceAssembler: Sendable, Equatable {
    public var gapMs: Int
    /// A chunk the recognizer finalized is reported as final only after this much quiet: with
    /// frequent finalization a chunk can end mid-command ("google search norbert" | "wiener"),
    /// and a final mid-command would commit a truncated payload.
    public var finalQuietMs: Int
    public private(set) var seq = 0
    private var finalSent = false
    public private(set) var committed: [String] = []
    public private(set) var volatile = ""
    public private(set) var allFinal = false
    public private(set) var lastChangeAt: TimeInterval = 0
    public private(set) var lastLoudAt: TimeInterval = 0

    public init(gapMs: Int = 1500, finalQuietMs: Int = 400) { self.gapMs = gapMs; self.finalQuietMs = finalQuietMs }

    public var utteranceId: String { "u\(seq)" }
    public var text: String { (committed + [volatile]).filter { !$0.isEmpty }.joined(separator: " ") }

    /// Applies one recognizer event. Returns the revision to send, or nil when nothing changed.
    public mutating func apply(segmentText: String, isFinal: Bool, at: TimeInterval) -> TranscriptRevision? {
        let before = (text, allFinal)
        if isFinal {
            let t = segmentText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { committed.append(t) }
            volatile = ""; allFinal = true
        } else {
            volatile = segmentText.trimmingCharacters(in: .whitespaces); allFinal = false
        }
        let now = (text, allFinal)
        guard now != before else { return nil }
        lastChangeAt = at   // any recognizer activity (new words or a finalization) restarts the quiet clock
        if now.0 != before.0 { finalSent = false }
        guard !text.isEmpty, now.0 != before.0 else { return nil }
        return TranscriptRevision(utteranceId: utteranceId, text: text, isFinal: false, at: at)
    }

    /// The final revision, once everything is finalized and the mic has been quiet for
    /// `finalQuietMs`; sent once per text. VoiceLoop polls this from its tick.
    public mutating func pendingFinal(now: TimeInterval) -> TranscriptRevision? {
        guard allFinal, !finalSent, !text.isEmpty, quietMs(now: now) >= Double(finalQuietMs) else { return nil }
        finalSent = true
        return TranscriptRevision(utteranceId: utteranceId, text: text, isFinal: true, at: now)
    }

    /// Hold-to-talk released: the key is the end-of-speech signal, so everything said so far is
    /// the utterance, final now, with no quiet window. Sent once; nil when nothing was said.
    public mutating func releaseFinal(at: TimeInterval) -> TranscriptRevision? {
        guard !text.isEmpty, !finalSent else { return nil }
        finalSent = true
        return TranscriptRevision(utteranceId: utteranceId, text: text, isFinal: true, at: at)
    }

    public mutating func noteLoud(at: TimeInterval) { lastLoudAt = max(lastLoudAt, at) }

    /// Milliseconds since the transcript last changed or the mic was last loud. A mic that never
    /// goes quiet (a noisy room) stops counting once the recognizer has been idle for
    /// `noisyRoomStableMs` beyond the gap: the words have stopped, whatever the room is doing.
    public func quietMs(now: TimeInterval) -> Double {
        let sinceWords = (now - lastChangeAt) * 1000
        if sinceWords >= Double(gapMs + Config.noisyRoomStableMs) { return sinceWords }
        return (now - max(lastLoudAt, lastChangeAt)) * 1000
    }

    /// True when the utterance should close: finalized, non-empty, and quiet for `gapMs`.
    public func shouldClose(now: TimeInterval) -> Bool {
        !text.isEmpty && allFinal && quietMs(now: now) >= Double(gapMs)
    }

    /// Starts the next utterance; returns the text that was dropped or consumed.
    @discardableResult
    public mutating func close() -> String {
        let t = text
        seq += 1; committed = []; volatile = ""; allFinal = false; finalSent = false
        return t
    }
}
