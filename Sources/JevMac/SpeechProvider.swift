import Foundation
import JevCore
import os

/// One transcript revision. `committedText` is every finalized segment joined; `volatileText`
/// is the current unfinalized tail. `text` is what the controller sends to Jev.
public struct TranscriptEvent: Sendable, Codable, Equatable {
    public let at: TimeInterval
    public let segment: Int
    public let committedText: String
    public let volatileText: String
    /// True when this event finalized a segment.
    public let isFinal: Bool
    /// The text this event is about: the volatile tail, or the segment that was just finalized.
    public let segmentText: String

    public init(at: TimeInterval, segment: Int, committedText: String, volatileText: String, isFinal: Bool, segmentText: String) {
        self.at = at; self.segment = segment; self.committedText = committedText
        self.volatileText = volatileText; self.isFinal = isFinal; self.segmentText = segmentText
    }

    public var text: String {
        [committedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum SpeechEvent: Sendable {
    case transcript(TranscriptEvent)
    case status(String)
    case error(String)
}

/// The boundary between the recognizer and the controller. Both providers emit the same
/// events, so Phase 0 can measure them side by side and Phase 3 can swap them by config.
public protocol SpeechProvider: AnyObject, Sendable {
    var name: String { get }
    var events: AsyncStream<SpeechEvent> { get }
    func start() async throws
    /// Finalize the volatile tail in place without stopping recognition (plan 9.5, 10).
    func commitSegment() async
    func stop() async
}

public enum SpeechProviderError: Error, CustomStringConvertible {
    case notAuthorized(String)
    case unavailable(String)
    case assetMissing(String)
    public var description: String {
        switch self {
        case .notAuthorized(let m): "speech not authorized: \(m)"
        case .unavailable(let m): "speech unavailable: \(m)"
        case .assetMissing(let m): "speech model missing: \(m)"
        }
    }
}

/// Tracks committed segments and the volatile tail for a provider. Not thread-safe on its own;
/// each provider serializes access.
struct TranscriptAccumulator {
    private(set) var committed: [String] = []
    private(set) var volatile: String = ""
    private(set) var segment = 0

    var committedText: String { committed.joined(separator: " ") }

    mutating func update(volatile text: String, at: TimeInterval) -> TranscriptEvent {
        volatile = text
        return TranscriptEvent(at: at, segment: segment, committedText: committedText, volatileText: volatile, isFinal: false, segmentText: text)
    }

    mutating func finalize(text: String, at: TimeInterval) -> TranscriptEvent {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { committed.append(t) }
        volatile = ""
        segment += 1
        return TranscriptEvent(at: at, segment: segment, committedText: committedText, volatileText: "", isFinal: true, segmentText: t)
    }

    mutating func reset() { committed = []; volatile = ""; segment = 0 }
}


/// Runs `op` and returns true if it finished within `seconds`. A hung operation is left to
/// finish on its own (or be torn down with the process) rather than blocking the caller.
func finishesWithin(seconds: Double, _ op: @escaping @Sendable () async -> Void) async -> Bool {
    let done = OSAllocatedUnfairLock(initialState: false)
    let task = Task.detached { await op(); done.withLock { $0 = true } }
    let deadline = Mono.now() + seconds
    while Mono.now() < deadline {
        if done.withLock({ $0 }) { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    task.cancel()
    return false
}
