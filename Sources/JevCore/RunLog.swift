import Foundation
import os

/// One line per event in `runs/<ts>/events.jsonl` plus a `summary.json` at close (plan section
/// 13). Every run records the model id, the question-catalog version, and the policy version so a
/// replay knows what produced it. With `redact` on (the bundle's default) transcripts, payloads,
/// and element text are logged as short hashes.
public final class RunLog: @unchecked Sendable {
    public struct Event: Codable, Sendable {
        public var t: TimeInterval          // monotonic seconds
        public var kind: String
        public var data: JSONValue
    }

    public struct Summary: Codable, Sendable {
        public var startedAt: String
        public var endedAt: String?
        public var model: String
        public var questionsVersion: String
        public var policyVersion: String
        public var appVersion: String
        public var redacted: Bool
        public var jevCalls: Int = 0
        public var jevCancelled: Int = 0
        public var inputTokens: Int = 0
        public var costUSD: Double = 0
        public var decisions: [String: Int] = [:]
        public var actions: Int = 0
        public var verified: Int = 0
        public var failed: Int = 0
        public var unknown: Int = 0
        public var duplicateDispatches: Int = 0
        public var jevLatencyMs: [Double] = []
        public var lastWordToDispatchMs: [Double] = []
        public var clauseToResponseMs: [Double] = []
        public var axCallsPerSnapshot: [Int] = []

        public var jevLatencyP50: Double? { RunLog.percentile(jevLatencyMs, 0.5) }
        public var jevLatencyP95: Double? { RunLog.percentile(jevLatencyMs, 0.95) }
    }

    public static let policyVersion = "p2"   // p2 (2026-09-28): commit window per intent, open-page search site, "for" dropped from queries

    public let directory: URL
    public let redact: Bool
    private let handle: FileHandle?
    private let state = OSAllocatedUnfairLock(uncheckedState: (summary: Summary?.none, seenDispatch: Set<String>()))
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()

    public init(runsRoot: URL, redact: Bool, appVersion: String = "0.1.0") throws {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = runsRoot.appending(path: ts)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = directory.appending(path: "events.jsonl")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        handle = try FileHandle(forWritingTo: events)
        self.redact = redact
        state.withLockUnchecked {
            $0.summary = Summary(startedAt: ts, model: Config.model, questionsVersion: Questions.version,
                                 policyVersion: Self.policyVersion, appVersion: appVersion, redacted: redact)
        }
    }

    /// A log that writes nowhere, for tests.
    public static func discarding() -> RunLog { try! RunLog(runsRoot: FileManager.default.temporaryDirectory.appending(path: "jev-cua-discard"), redact: false) }

    public func text(_ s: String) -> JSONValue {
        redact ? .string("h:" + SHA.hex(Data(s.utf8)).prefix(10)) : .string(s)
    }

    public func log(_ kind: String, _ data: [String: JSONValue] = [:]) {
        let ev = Event(t: Mono.now(), kind: kind, data: .object(data))
        guard var line = try? encoder.encode(ev) else { return }
        line.append(contentsOf: [0x0A])
        // One write per line, under the lock: events come from several threads (session, UI,
        // hot key) and interleaved writes produced lines with two objects on 2026-09-20.
        state.withLockUnchecked { _ in handle?.write(line) }
    }

    // MARK: Summary accounting

    public func recordJev(_ resp: JevResponse) {
        state.withLockUnchecked {
            $0.summary?.jevCalls += 1
            $0.summary?.inputTokens += resp.usage.inputTokens
            $0.summary?.costUSD += resp.usage.costUSD
            if resp.latencyMs > 0 { $0.summary?.jevLatencyMs.append(resp.latencyMs) }
        }
    }
    public func recordJevCancelled() { state.withLockUnchecked { $0.summary?.jevCancelled += 1 } }
    public func recordDecision(_ outcome: String) { state.withLockUnchecked { $0.summary?.decisions[outcome, default: 0] += 1 } }
    public func recordDispatch(_ ledger: LedgerEntry) {
        state.withLockUnchecked {
            $0.summary?.actions += 1
            let key = "\(ledger.utteranceId)#\(ledger.candidateId)"
            if !$0.seenDispatch.insert(key).inserted { $0.summary?.duplicateDispatches += 1 }
        }
    }
    public func recordVerification(_ v: Verification) {
        state.withLockUnchecked {
            switch v.outcome {
            case .verified: $0.summary?.verified += 1
            case .failed: $0.summary?.failed += 1
            case .unknown: $0.summary?.unknown += 1
            }
        }
    }
    public func recordLatency(lastWordToDispatchMs: Double?, clauseToResponseMs: Double?) {
        state.withLockUnchecked {
            if let l = lastWordToDispatchMs { $0.summary?.lastWordToDispatchMs.append(l) }
            if let c = clauseToResponseMs { $0.summary?.clauseToResponseMs.append(c) }
        }
    }
    public func recordSnapshot(axCalls: Int) { state.withLockUnchecked { $0.summary?.axCallsPerSnapshot.append(axCalls) } }

    public func close() {
        var summary = state.withLockUnchecked { $0.summary }
        summary?.endedAt = ISO8601DateFormatter().string(from: Date())
        if let summary, let data = try? { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return try e.encode(summary) }() {
            try? data.write(to: directory.appending(path: "summary.json"))
        }
        try? handle?.close()
    }

    public var summary: Summary? { state.withLockUnchecked { $0.summary } }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }
}
