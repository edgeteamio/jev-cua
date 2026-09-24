import Foundation

/// Phase 3 acceptance (plan section 12): aligns a live run's utterances to a spoken trial
/// script and scores fires, false fires, stop latency, and last-word-to-dispatch latency.
public enum Trials {
    public struct Trial: Codable, Sendable {
        public var say: String
        public var expect: [String]
        public var pending: String?
        public var stop: Bool?
        public var note: String?
    }
    public struct Script: Codable, Sendable { public var trials: [Trial] }

    public struct Utterance: Sendable {
        public var id: String
        public var texts: [String] = []
        public var finalText: String { texts.last ?? "" }
        public var actions: [String] = []          // action kinds dispatched
        public var pending: String?
        public var cancelled = false
        public var lastWordToDispatchMs: [Double] = []
        public var stopAt: TimeInterval?
        public var cancelAt: TimeInterval?
    }

    public struct Row: Sendable {
        public var index: Int
        public var say: String
        public var expect: [String]
        public var matched: Utterance?
        public var ok: Bool
        public var why: String
        /// True for stop and confirmation-gate trials (their empty expectation is not chatter).
        public var stopOrPending: Bool { why.contains("stop") || why.contains("confirmation") || why.contains("cancel") }
    }

    public struct Report: Sendable {
        public var rows: [Row]
        public var unmatchedUtterances: [Utterance]
        public var falseFires: Int
        public var stopLatenciesMs: [Double]
        public var dispatchLatenciesMs: [Double]
        public var correct: Int { rows.filter(\.ok).count }
    }

    public static func utterances(from events: [RunLog.Event]) -> [Utterance] {
        var byId: [String: Utterance] = [:]
        var order: [String] = []
        func u(_ id: String) -> Utterance { byId[id] ?? { order.append(id); return Utterance(id: id) }() }
        var lastId: String?
        for e in events {
            switch e.kind {
            case "transcript":
                guard let id = e.data["utterance"]?.stringValue, let t = e.data["text"]?.stringValue else { continue }
                var x = u(id); x.texts.append(t); byId[id] = x; lastId = id
            case "dispatch":
                guard let id = lastId, let action = e.data["action"]?.stringValue else { continue }
                var x = u(id); x.actions.append(String(action.split(separator: " ").first ?? "")); 
                if let ms = e.data["last_word_to_dispatch_ms"]?.doubleValue { x.lastWordToDispatchMs.append(ms) }
                byId[id] = x
            case "kill":
                guard let id = lastId else { continue }
                var x = u(id); x.stopAt = e.t; x.cancelled = true; byId[id] = x
            case "cancel":
                guard let id = lastId else { continue }
                var x = u(id); x.cancelAt = x.cancelAt ?? e.t; x.cancelled = true; byId[id] = x
            case "decision":
                guard let id = e.data["utterance"]?.stringValue else { continue }
                if e.data["outcome"]?.stringValue == "confirm" { var x = u(id); x.pending = e.data["candidate"]?.stringValue; byId[id] = x }
            default: break
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// Order-preserving alignment (dynamic programming) between the script and the utterances:
    /// each trial matches the utterance whose revisions share enough words with what was to be
    /// said; room chatter and skipped trials cost nothing; an utterance may hold two consecutive
    /// trials ("launch photo booth" and "switch to chrome" in one breath), which are then scored
    /// against its actions back to back.
    public static func score(script: Script, events: [RunLog.Event]) -> Report {
        let utts = utterances(from: events).filter { !$0.finalText.isEmpty }
        func keyWords(_ say: String) -> Set<String> {
            Set(Transcript.normalize(say.replacingOccurrences(of: "...", with: " ")).split(separator: " ").map(String.init)
                .filter { $0.count >= 2 && !["stop", "never", "mind", "the", "and", "to", "of", "me", "in", "it", "a", "for"].contains($0) })
        }
        let uttWords: [Set<String>] = utts.map { u in Set(u.texts.flatMap { Transcript.normalize($0).split(separator: " ").map(String.init) }) }
        let keys = script.trials.map { keyWords($0.say) }
        func matches(_ i: Int, _ j: Int) -> Bool {
            let k = keys[i]; guard !k.isEmpty else { return false }
            return Double(k.intersection(uttWords[j]).count) / Double(k.count) >= 0.5
        }
        let n = script.trials.count, m = utts.count
        // best[i][j]: best matched count using trials[0..<i] and utterances[0..<j]; back tracks the move.
        var best = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)   // 1 skip trial, 2 skip utt, 3 match, 4 match same utt (merge)
        for i in 1...max(1, n) where n > 0 {
            for j in 0...m {
                var b = best[i - 1][j], mv = 1
                if j > 0, best[i][j - 1] > b { b = best[i][j - 1]; mv = 2 }
                if j > 0, matches(i - 1, j - 1) {
                    if best[i - 1][j - 1] + 1 > b { b = best[i - 1][j - 1] + 1; mv = 3 }
                    // Merge: the previous trial also sits in this utterance.
                    if i > 1, back[i - 1][j] == 3 || back[i - 1][j] == 4, best[i - 1][j] + 1 > b { b = best[i - 1][j] + 1; mv = 4 }
                }
                best[i][j] = b; back[i][j] = mv
            }
        }
        var assignment = Array(repeating: -1, count: n)
        var i = n, j = m
        while i > 0, j >= 0 {
            switch back[i][j] {
            case 3: assignment[i - 1] = j - 1; i -= 1; j -= 1
            case 4: assignment[i - 1] = j - 1; i -= 1
            case 2: j -= 1
            default: i -= 1
            }
            if j < 0 { break }
        }
        // Score per utterance group.
        var rows: [Row] = []
        var used = Set<Int>()
        var idx = 0
        while idx < n {
            let t = script.trials[idx]
            guard assignment[idx] >= 0 else {
                rows.append(Row(index: idx + 1, say: t.say, expect: t.expect, matched: nil, ok: false, why: "no matching utterance")); idx += 1; continue
            }
            let uj = assignment[idx]
            used.insert(uj)
            var group = [idx]
            while group.last! + 1 < n, assignment[group.last! + 1] == uj { group.append(group.last! + 1) }
            let u = utts[uj]
            var remaining = u.actions
            for gi in group {
                let tr = script.trials[gi]
                let mine = Array(remaining.prefix(max(1, tr.expect.count)))
                var ok = false
                var why = ""
                if tr.stop == true {
                    ok = remaining.isEmpty && u.cancelled
                    why = ok ? "stopped, no action" : (remaining.isEmpty ? "no action but no cancel seen" : "acted: \(remaining.joined(separator: ","))")
                } else if let p = tr.pending {
                    ok = remaining.isEmpty && (u.pending ?? "").hasPrefix(p)
                    why = ok ? "held for confirmation" : (remaining.isEmpty ? "no pending confirmation" : "acted without confirmation")
                } else if tr.expect.isEmpty {
                    ok = remaining.isEmpty
                    why = ok ? "no action" : "FALSE FIRE: \(remaining.joined(separator: ","))"
                } else if tr.note?.contains("either") == true {
                    ok = !mine.isEmpty && tr.expect.contains(mine[0])
                    why = ok ? "acted \(mine[0])" : "acted \(mine.isEmpty ? "nothing" : mine.joined(separator: ","))"
                    remaining = Array(remaining.dropFirst(1))
                } else {
                    let taken = Array(remaining.prefix(tr.expect.count))
                    ok = taken == tr.expect && (gi != group.last! || remaining.count == tr.expect.count)
                    why = ok ? "acted \(taken.joined(separator: ","))" : "acted \(remaining.isEmpty ? "nothing" : remaining.joined(separator: ","))"
                    remaining = Array(remaining.dropFirst(tr.expect.count))
                }
                rows.append(Row(index: gi + 1, say: tr.say, expect: tr.expect, matched: u, ok: ok, why: why + (group.count > 1 ? " (merged utterance)" : "")))
            }
            idx = group.last! + 1
        }
        let unmatched = utts.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        // A false fire is an action on words that were not a scripted command: a chatter trial
        // that acted, or an unmatched utterance that acted.
        let falseFires = rows.filter { $0.expect.isEmpty && $0.stopOrPending == false && $0.why.hasPrefix("FALSE") }.count
            + unmatched.filter { !$0.actions.isEmpty }.count
        let stops = rows.compactMap { r -> Double? in
            guard let u = r.matched, let s = u.stopAt, let c = u.cancelAt else { return nil }
            return max(0, (c - s) * 1000)
        }
        let dispatches = rows.flatMap { $0.matched?.lastWordToDispatchMs ?? [] }
        return Report(rows: rows, unmatchedUtterances: unmatched, falseFires: falseFires, stopLatenciesMs: stops, dispatchLatenciesMs: dispatches)
    }

    public static func render(_ r: Report) -> String {
        var out = "trials: \(r.correct)/\(r.rows.count) correct; false fires \(r.falseFires); "
        out += "last word → dispatch p50 \(pct(r.dispatchLatenciesMs, 0.5)) ms, p95 \(pct(r.dispatchLatenciesMs, 0.95)) ms (n=\(r.dispatchLatenciesMs.count)); "
        out += "stop → cancel p50 \(pct(r.stopLatenciesMs, 0.5)) ms (n=\(r.stopLatenciesMs.count))\n"
        for row in r.rows {
            out += String(format: "%@ %2d. \"%@\" → %@%@\n", row.ok ? "✓" : "✗", row.index, row.say, row.why,
                          row.matched.map { " [heard: \"\($0.finalText)\"]" } ?? "")
        }
        if !r.unmatchedUtterances.isEmpty {
            out += "unmatched utterances (\(r.unmatchedUtterances.count)):\n"
            for u in r.unmatchedUtterances { out += "    \"\(u.finalText)\"\(u.actions.isEmpty ? "" : " → \(u.actions.joined(separator: ","))")\n" }
        }
        return out
    }

    static func pct(_ xs: [Double], _ p: Double) -> String {
        guard !xs.isEmpty else { return "-" }
        let s = xs.sorted()
        return String(Int(s[min(s.count - 1, Int(Double(s.count - 1) * p))]))
    }
}
