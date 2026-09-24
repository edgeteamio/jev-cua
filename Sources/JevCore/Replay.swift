import Foundation

/// `jev-cua replay runs/<ts>` (plan Phase 5): re-runs the policy over the answers a run logged,
/// with the current thresholds and candidate builder, and diffs the outcomes. No model call.
/// Needs an unredacted run (the record carries transcripts and spans).
public enum Replay {
    public struct Row: Sendable, Codable {
        public var utterance: String
        public var revision: Int
        public var transcript: String
        public var loggedOutcome: String
        public var loggedSummary: String
        public var loggedCandidate: String?
        public var newOutcome: String
        public var newSummary: String
        public var newCandidate: String?
        public var same: Bool
    }

    public struct Report: Sendable, Codable {
        public var run: String
        public var policyVersionLogged: String?
        public var questionsVersionLogged: String?
        public var rows: [Row]
        public var skippedRedacted: Int
        public var changed: Int { rows.filter { !$0.same }.count }
    }

    public static func run(directory: URL) throws -> Report {
        let events = try String(contentsOf: directory.appending(path: "events.jsonl"), encoding: .utf8)
        var rows: [Row] = []
        var skipped = 0
        for line in events.split(separator: "\n") {
            guard let ev = try? JSONDecoder().decode(RunLog.Event.self, from: Data(line.utf8)), ev.kind == "decision" else { continue }
            guard let replay = ev.data["replay"],
                  let answers = replay["answers"]?.decoded(as: [String: Answer].self),
                  let spans = replay["spans"]?.decoded(as: SpanSet.self),
                  let context = replay["context"]?.decoded(as: DecisionContext.self) else { skipped += 1; continue }
            let pending = replay["pending"].flatMap { $0 == .null ? nil : $0.decoded(as: Candidate.self) }
            let input = PolicyInput(answers: answers, spans: spans, context: context, silentMs: replay["silent_ms"]?.doubleValue ?? 0,
                                    intentStable: replay["intent_stable"]?.boolValue ?? false, pending: pending,
                                    snapshotId: replay["snapshot"]?.stringValue ?? "replay")
            let result = Policy.evaluate(input)
            let loggedOutcome = ev.data["outcome"]?.stringValue ?? "?"
            let loggedSummary = ev.data["summary"]?.stringValue ?? ""
            let loggedCandidate = ev.data["candidate"]?.stringValue
            let newCandidate = result.candidate?.action.summary
            rows.append(Row(utterance: ev.data["utterance"]?.stringValue ?? "?", revision: Int(ev.data["revision"]?.doubleValue ?? 0),
                            transcript: context.rawTranscript, loggedOutcome: loggedOutcome, loggedSummary: loggedSummary,
                            loggedCandidate: loggedCandidate, newOutcome: result.outcome.name, newSummary: result.summary, newCandidate: newCandidate,
                            same: loggedOutcome == result.outcome.name && loggedCandidate == newCandidate))
        }
        var policyVersion: String?, questionsVersion: String?
        if let data = try? Data(contentsOf: directory.appending(path: "summary.json")),
           let summary = try? JSONDecoder().decode(RunLog.Summary.self, from: data) {
            policyVersion = summary.policyVersion; questionsVersion = summary.questionsVersion
        }
        return Report(run: directory.lastPathComponent, policyVersionLogged: policyVersion, questionsVersionLogged: questionsVersion, rows: rows, skippedRedacted: skipped)
    }

    public static func render(_ r: Report) -> String {
        var out = "replay \(r.run): \(r.rows.count) decisions, \(r.changed) changed"
        if let p = r.policyVersionLogged { out += " (logged policy \(p), questions \(r.questionsVersionLogged ?? "?"); now \(RunLog.policyVersion), \(Questions.version))" }
        if r.skippedRedacted > 0 { out += "; \(r.skippedRedacted) skipped (redacted or pre-replay records)" }
        out += "\n"
        for row in r.rows {
            let mark = row.same ? " " : "≠"
            out += String(format: "%@ %@#%d \"%@\"\n    logged: %@ — %@%@\n", mark, row.utterance, row.revision, row.transcript, row.loggedOutcome, row.loggedSummary,
                          row.loggedCandidate.map { " [\($0)]" } ?? "")
            if !row.same { out += String(format: "    now:    %@ — %@%@\n", row.newOutcome, row.newSummary, row.newCandidate.map { " [\($0)]" } ?? "") }
        }
        return out
    }
}
