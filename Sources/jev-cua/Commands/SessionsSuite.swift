import AppKit
import Foundation
import JevCore
import JevMac

/// `jev-cua sessions <suite.json> [--runs N] [--only <text>]`
/// Live regression suite for session mode: each case feeds typed phrases to one CommandSession
/// in order, as `say` does, then checks evidence on a fresh observation. It holds what the goals
/// suite cannot: follow-ups, repeats, placements, menu commands. A case passes when its evidence
/// holds, no action failed, and at least one action ran.
enum SessionsSuite {
    /// `expected_fail` keeps a case that documents a known limit in the suite without failing it:
    /// it reports as "known limit" while it fails and as "FIXED, untag" once it passes.
    struct Case: Decodable { var name: String; var setup: GoalsSuite.Setup?; var phrases: [String]; var check: SuiteCheck; var note: String?; var expected_fail: Bool? }
    struct Suite: Decodable { var cases: [Case] }

    /// What the session did, gathered from its events.
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var actionsList: [String] = []
        private var lastAction: (action: String, verified: Bool)? = nil
        private var failedCount = 0
        func on(_ e: SessionEvent) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .dispatched(_, let c): actionsList.append(c.summary); lastAction = (c.summary, false)
            case .executed(_, let o):
                if let l = lastAction { lastAction = (l.action, o.verification.outcome == .verified) }
                if o.result.status == .failed || o.verification.outcome == .failed { failedCount += 1 }
            default: break
            }
        }
        var actions: [String] { lock.lock(); defer { lock.unlock() }; return actionsList }
        var last: (action: String, verified: Bool)? { lock.lock(); defer { lock.unlock() }; return lastAction }
        var failed: Int { lock.lock(); defer { lock.unlock() }; return failedCount }
    }

    static func run(_ args: Args) async throws {
        guard let path = args.positional.first else { throw UsageError("usage: jev-cua sessions <suite.json> [--runs N] [--only <text>]") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: cwd.appending(path: path)))
        let runs = args.int("runs", default: 1)
        let only = args.string("only")
        let log = try RunLog(runsRoot: cwd.appending(path: "runs"), redact: false)
        defer { log.close() }
        let live = try JevClient()
        let decider: any JevDeciding = args.flag("no-cache") ? live : JevCache(path: JevCache.livePath(cwd), live: live)
        let perception = MacPerception(log: log)
        let executor = MacExecutor(mode: .live, log: log, resolver: perception)
        var cfg = CommandSession.Config()
        cfg.installedApps = InstalledApps.names()
        cfg.runningApps = Set(NSWorkspaceRunning.names())

        var lines: [String] = []
        var totals = (passed: 0, runs: 0)
        for c in suite.cases where only == nil || c.name.localizedCaseInsensitiveContains(only!) {
            var p = 0, n = 0
            var notes: [String] = []
            for r in 1...runs {
                await GoalsSuite.setup(c.setup)
                await perception.invalidate()
                let trace = Trace()
                let session = CommandSession(decider: decider, perception: perception, executor: executor, log: log, config: cfg) { trace.on($0) }
                let t0 = Mono.now()
                for (i, text) in c.phrases.enumerated() {
                    await session.handleTranscript(TranscriptRevision(utteranceId: "case-\(i + 1)", text: text, isFinal: true, at: Mono.now()))
                    for _ in 0..<600 {
                        try? await Task.sleep(for: .milliseconds(25))
                        if await session.isIdle { break }
                    }
                    await session.endUtterance(reason: "typed")
                }
                try? await Task.sleep(for: .milliseconds(400))
                await perception.invalidate()
                let obs = await perception.observe()
                let evidence = c.check.evaluate(obs: obs, actions: trace.actions, last: trace.last)
                let ok = evidence.ok && trace.failed == 0 && !trace.actions.isEmpty
                let known = c.expected_fail == true
                n += 1; if ok || known { p += 1 }
                let why = ok ? "evidence ok" : [evidence.ok ? nil : evidence.why, trace.failed > 0 ? "\(trace.failed) failed action(s)" : nil,
                                                trace.actions.isEmpty ? "no action taken" : nil].compactMap { $0 }.joined(separator: "; ")
                let tag = ok ? (known ? "FIXED, untag expected_fail" : "pass") : (known ? "known limit" : "FAIL")
                notes.append(String(format: "  r%d %@: %@ | %.1f s | %@", r, tag, why, Mono.now() - t0, trace.actions.joined(separator: " → ")))
                print(notes.last!)
            }
            lines.append("\(c.name): \(p)/\(n) passed"); lines += notes
            totals.passed += p; totals.runs += n
        }
        let summary = "sessions: \(totals.passed)/\(totals.runs) passed, \(totals.runs - totals.passed) failed"
        print("\n" + summary)
        let out = log.directory.appending(path: "sessions.md")
        try ("# Session suite \(log.directory.lastPathComponent)\n\n" + summary + "\n\n```\n" + lines.joined(separator: "\n") + "\n```\n").write(to: out, atomically: true, encoding: .utf8)
        print("wrote \(out.path)")
        if let cache = decider as? JevCache { try? cache.save() }
    }
}
