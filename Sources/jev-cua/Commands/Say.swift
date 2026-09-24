import Foundation
import JevCore
import JevMac

/// `jev-cua say "<command>" [--step] [--dry-run] [--redact] [--no-cache]`
/// Runs the full pipeline on typed text as a final utterance: perception, Jev, policy, executor,
/// verification, run log. `--step` shows the candidate and the gate table and waits for Enter
/// before executing; `--dry-run` stops there (plan Phase 2).
enum Say {
    static func run(_ args: Args) async throws {
        guard !args.positional.isEmpty, !args.positional[0].isEmpty else { throw UsageError("usage: jev-cua say \"<command>\" [\"<next phrase>\" ...] [--step] [--dry-run]") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let log = try RunLog(runsRoot: cwd.appending(path: "runs"), redact: args.flag("redact"))
        defer { log.close() }

        let live = try JevClient()
        let decider: any JevDeciding = args.flag("no-cache") ? live : JevCache(path: JevCache.livePath(cwd), live: live)
        let perception = MacPerception(log: log)
        let executor = MacExecutor(mode: args.flag("dry-run") ? .dryRun : .live, log: log, resolver: perception)
        let stepping = args.flag("step")
        let gate = StepGate(enabled: stepping, dryRun: args.flag("dry-run"), inner: executor)

        var cfg = CommandSession.Config()
        cfg.installedApps = InstalledApps.names()
        cfg.runningApps = Set(NSWorkspaceRunning.names())
        let printer = EventPrinter()
        let session = CommandSession(decider: decider, perception: perception, executor: gate, log: log, config: cfg) { printer.print($0) }

        let t0 = Mono.now()
        // Each positional phrase is its own utterance, in order: "open wikipedia" "mark zuckerberg"
        // exercises a follow-up against the previous action inside one session.
        for (i, text) in args.positional.enumerated() {
            if i > 0 { print("— next utterance —") }
            await session.handleTranscript(TranscriptRevision(utteranceId: "typed-\(i + 1)", text: text, isFinal: true, at: Mono.now()))
            // Settle: wait for the session to go idle (decisions, reruns on remaining clauses, executions).
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(25))
                if await session.isIdle { break }
            }
            await session.endUtterance(reason: "typed")
        }
        if let pending = await session.pendingCandidate {
            print("pending confirmation: \(pending.action.summary)  (say \"confirm\" or \"cancel\" in the next command)")
        }
        let s = log.summary
        print(String(format: "\n%.0f ms total; jev %d calls p50 %.0f ms; actions %d (verified %d, unknown %d, failed %d); log %@",
                     (Mono.now() - t0) * 1000, s?.jevCalls ?? 0, s?.jevLatencyP50 ?? 0, s?.actions ?? 0, s?.verified ?? 0, s?.unknown ?? 0, s?.failed ?? 0,
                     log.directory.lastPathComponent))
        if let cache = decider as? JevCache { try? cache.save() }
    }
}

/// Wraps the executor to pause before each action (`--step`) or skip it (`--dry-run`).
final class StepGate: Executing, @unchecked Sendable {
    let enabled: Bool
    let dryRun: Bool
    let inner: MacExecutor
    init(enabled: Bool, dryRun: Bool, inner: MacExecutor) { self.enabled = enabled; self.dryRun = dryRun; self.inner = inner }

    func execute(_ candidate: Candidate, observation: Observation) async -> ExecutionOutcome {
        if enabled && !dryRun {
            print("  about to execute: \(candidate.action.summary)   [Enter to run, s to skip]")
            let line = readLine() ?? ""
            if line.trimmingCharacters(in: .whitespaces).lowercased() == "s" {
                return ExecutionOutcome(result: ActionResult(dispatchId: "", status: .failed, detail: "skipped by user", tookMs: 0),
                                        verification: Verification(dispatchId: "", expected: candidate.expectedPostcondition, observed: "skipped", outcome: .unknown, evidence: .none, nextStep: ""))
            }
        }
        return await inner.execute(candidate, observation: observation)
    }
}

final class EventPrinter: @unchecked Sendable {
    func print(_ e: SessionEvent) {
        switch e {
        case .transcript(_, let text, let consumed, let isFinal):
            Swift.print("transcript: \"\(text)\"\(consumed.isEmpty ? "" : "  (after: \"\(consumed)\")")\(isFinal ? " [final]" : "")")
        case .deciding: break
        case .decided(let d, let summary, _):
            let gates = d.reasons.map { "\($0.name)=\($0.value)\($0.pass ? "" : " ✗")" }.joined(separator: "  ")
            Swift.print(String(format: "decision: %@ — %@   (%.0f ms, %d tokens)\n  gates: %@", d.outcome.name, summary, d.latencyMs, d.usage.inputTokens, gates))
        case .dispatched(_, let c):
            Swift.print("dispatch: \(c.summary)")
        case .executed(_, let o):
            Swift.print(String(format: "result: %@ (%@) in %.0f ms; verification %@ via %@: %@", o.result.status.rawValue, o.result.detail, o.result.tookMs,
                               o.verification.outcome.rawValue, o.verification.evidence.rawValue, o.verification.observed))
        case .pendingConfirmation(let c):
            if let c { Swift.print("confirm? \(c.action.summary)") }
        case .disambiguation(let els):
            if let els { Swift.print("which one? " + els.enumerated().map { "\($0.offset + 1): \($0.element.role) '\($0.element.text)'" }.joined(separator: "  ")) }
        case .cancelled(let r): Swift.print("cancelled: \(r)")
        case .error(let m): Swift.print("error: \(m)")
        }
    }
}

enum NSWorkspaceRunning {
    static func names() -> [String] {
        AppKitBridge.runningAppNames()
    }
}
