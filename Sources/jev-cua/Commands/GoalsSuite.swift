import AppKit
import Foundation
import JevCore
import JevMac

/// `jev-cua goals fixtures/goals/phase6.json [--runs N] [--only <substring>] [--no-escalation]`
/// Phase 6 acceptance: every workflow, every phrasing, N runs each. Completion evidence is checked
/// from a fresh observation after the run, independently of the loop's own verdict, so a false
/// completion (achieved but the evidence is missing) is counted as such.
enum GoalsSuite {
    struct Setup: Decodable { var open_url: String?; var open_app: String? }
    struct Workflow: Decodable { var name: String; var setup: Setup?; var phrasings: [String]; var check: SuiteCheck }
    struct Suite: Decodable { var workflows: [Workflow] }

    static func run(_ args: Args) async throws {
        guard let path = args.positional.first else { throw UsageError("usage: jev-cua goals <suite.json> [--runs N] [--only <text>]") }
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
        let escalation: (any Escalating)? = args.flag("no-escalation") ? nil : AnthropicEscalation()
        var cfg = TaskRunner.Config()
        cfg.installedApps = InstalledApps.names()
        cfg.runningApps = Set(NSWorkspaceRunning.names())

        var lines: [String] = []
        var totals = (verified: 0, falseDone: 0, intervention: 0, failed: 0, runs: 0, escalations: 0, cost: 0.0)
        for wf in suite.workflows where only == nil || wf.name.localizedCaseInsensitiveContains(only!) {
            var v = 0, fd = 0, iv = 0, fl = 0, esc = 0, cost = 0.0, n = 0
            var notes: [String] = []
            for (pi, phrasing) in wf.phrasings.enumerated() {
                for r in 1...runs {
                    await setup(wf.setup)
                    await perception.invalidate()
                    let runner = TaskRunner(decider: decider, perception: perception, executor: executor, escalation: escalation, log: log, config: cfg)
                    let result = await runner.run(TaskSpec(goal: phrasing))
                    n += 1; esc += result.escalations; cost += result.costUSD
                    try? await Task.sleep(for: .milliseconds(400))
                    await perception.invalidate()
                    let obs = await perception.observe()
                    let acts = result.steps.filter { $0.kind == .act }
                    let evidence = wf.check.evaluate(obs: obs, actions: acts.compactMap(\.action),
                                                     last: acts.last.map { ($0.action ?? "", $0.verification?.hasPrefix("verified") == true) })
                    let tag: String
                    switch (result.outcome, evidence.ok) {
                    case (.achieved, true): v += 1; tag = "verified"
                    case (.achieved, false): fd += 1; tag = "FALSE COMPLETION"
                    case (.needsClarification, _), (.blocked, _), (.abstained, _): iv += 1; tag = "intervention (\(result.outcome.rawValue))"
                    default: fl += 1; tag = "failed (\(result.outcome.rawValue))"
                    }
                    let steps = result.steps.map { "\($0.kind == .act ? ($0.action ?? "") : $0.kind.rawValue)" }.joined(separator: " → ")
                    notes.append(String(format: "  p%d r%d %@: %@ | %@ | %d steps, %.1f s, $%.4f%@", pi + 1, r, tag, result.detail, evidence.why, result.steps.count, result.elapsedS, result.costUSD, steps.isEmpty ? "" : " | " + steps))
                    print(notes.last!)
                }
            }
            lines.append("\(wf.name): \(v)/\(n) verified, \(fd) false completions, \(iv) interventions, \(fl) failed, \(esc) escalations, $\(String(format: "%.4f", cost))")
            lines += notes
            totals.verified += v; totals.falseDone += fd; totals.intervention += iv; totals.failed += fl; totals.runs += n; totals.escalations += esc; totals.cost += cost
        }
        let summary = "goals: \(totals.verified)/\(totals.runs) verified, \(totals.falseDone) false completions, \(totals.intervention) interventions, \(totals.failed) failed, \(totals.escalations) escalations, $\(String(format: "%.4f", totals.cost)) (escalation \(escalation?.name ?? "off"))"
        print("\n" + summary)
        let out = log.directory.appending(path: "goals.md")
        try ("# Goal suite \(log.directory.lastPathComponent)\n\n" + summary + "\n\n```\n" + lines.joined(separator: "\n") + "\n```\n").write(to: out, atomically: true, encoding: .utf8)
        print("wrote \(out.path)")
        if let cache = decider as? JevCache { try? cache.save() }
    }

    static func setup(_ s: Setup?) async {
        guard let s else { return }
        if let app = s.open_app, let entry = Config.apps.first(where: { $0.name == app }) {
            _ = await Apps.activate(bundleId: entry.bundleId, name: entry.name)
            try? await Task.sleep(for: .milliseconds(800))
        }
        // A path with no scheme is a file in this repository ("fixtures/goals/form.html").
        if let u = s.open_url, let url = u.contains("://") ? URL(string: u) : URL(fileURLWithPath: u, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).absoluteURL {
            _ = await Apps.activate(bundleId: "com.google.Chrome", name: "Google Chrome")
            try? await Task.sleep(for: .milliseconds(400))
            _ = await Apps.open(url: url, inAppAt: Apps.url(bundleId: "com.google.Chrome", name: "Google Chrome"))
            try? await Task.sleep(for: .milliseconds(1200))
            // Chrome reuses an open tab for the same URL: reload so every run starts from a fresh page.
            if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.processIdentifier {
                await Browser.reload(pid: pid)
            }
        }
    }
}
