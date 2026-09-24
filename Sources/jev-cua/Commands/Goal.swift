import Foundation
import JevCore
import JevMac

/// `jev-cua goal "<goal>" [--dry-run] [--max-steps N] [--no-escalation] [--no-intake] [--redact] [--no-cache]`
/// Goal mode (plan Phase 6): runs the TaskRunner loop against the real Mac, printing each step.
enum Goal {
    static func run(_ args: Args) async throws {
        guard let goal = args.positional.first, !goal.isEmpty else { throw UsageError("usage: jev-cua goal \"<goal>\" [--dry-run] [--max-steps N] [--no-escalation]") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let log = try RunLog(runsRoot: cwd.appending(path: "runs"), redact: args.flag("redact"))
        defer { log.close() }
        let live = try JevClient()
        let decider: any JevDeciding = args.flag("no-cache") ? live : JevCache(path: JevCache.livePath(cwd), live: live)
        let perception = MacPerception(log: log)
        let executor = MacExecutor(mode: args.flag("dry-run") ? .dryRun : .live, log: log, resolver: perception)
        let escalation: (any Escalating)? = args.flag("no-escalation") ? nil : AnthropicEscalation()
        if escalation == nil, !args.flag("no-escalation") { print("escalation: off (no \(AnthropicEscalation.keyName)); Jev only") }
        else if let e = escalation { print("escalation: \(e.name), budget \(Config.Goal.escalationBudget) calls") }

        var cfg = TaskRunner.Config()
        cfg.installedApps = InstalledApps.names()
        cfg.runningApps = Set(NSWorkspaceRunning.names())
        cfg.skipIntake = args.flag("no-intake")
        let runner = TaskRunner(decider: decider, perception: perception, executor: executor, escalation: escalation, log: log, config: cfg) { step in
            let mark: String = { switch step.kind { case .act: return "▶"; case .achieved: return "✓"; case .blocked: return "⛔"; case .reobserve: return "👁"; case .abstain: return "…"; case .clarify: return "?"; case .stop: return "•" } }()
            var line = String(format: "%@ step %d [%@] %@", mark, step.index, step.kind.rawValue, step.summary)
            if let v = step.verification { line += "  → \(v)" }
            if let e = step.escalation { line += "  [escalation: \(e)]" }
            line += String(format: "   (%.0f ms, %d tokens)", step.latencyMs, step.inputTokens)
            print(line)
            if !args.flag("quiet") {
                print("    gates: " + step.reasons.map { "\($0.name)=\($0.value)\($0.pass ? "" : " ✗")" }.joined(separator: "  "))
            }
        }
        var spec = TaskSpec(goal: goal)
        if let n = args.string("max-steps").flatMap(Int.init) { spec.stepBudget = n }
        let result = await runner.run(spec)
        print(String(format: "\nresult: %@ — %@   (%d steps, %d escalations, $%.4f, %.1f s); log %@",
                     result.outcome.rawValue, result.detail, result.steps.count, result.escalations, result.costUSD, result.elapsedS, log.directory.lastPathComponent))
        if let a = result.answer { print("answer: \(a)") }
        if let cache = decider as? JevCache { try? cache.save() }
    }
}
