import Foundation

/// Minimal argument parsing: `jev-cua <command> [--flag] [--option value|--option=value]`.
struct Args {
    let command: String?
    private(set) var flags: Set<String> = []
    private(set) var options: [String: String] = [:]
    private(set) var positional: [String] = []

    init(_ argv: [String]) {
        var tokens = argv[...]
        command = tokens.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if command != nil { tokens = tokens.dropFirst() }
        while let t = tokens.first {
            tokens = tokens.dropFirst()
            guard t.hasPrefix("--") else { positional.append(t); continue }
            let body = t.dropFirst(2)
            if let eq = body.firstIndex(of: "=") {
                options[String(body[..<eq])] = String(body[body.index(after: eq)...])
            } else if let next = tokens.first, !next.hasPrefix("--") {
                options[String(body)] = next
                tokens = tokens.dropFirst()
            } else {
                flags.insert(String(body))
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) || options[name] == "true" }
    func string(_ name: String) -> String? { options[name] }
    func int(_ name: String, default d: Int) -> Int { options[name].flatMap(Int.init) ?? d }
    func float(_ name: String, default d: Float) -> Float { options[name].flatMap(Float.init) ?? d }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum Usage {
    static let text = """
    jev-cua — voice-driven Mac computer use on TypeSafe Jev

    commands:
      doctor [--prompt] [--live]      permissions, speech model, key; --prompt requests grants,
                                      --live sends one Noul to the pinned model
      models                          list models the account can use
      speech-probe [--provider P] [--seconds N] [--level-threshold F] [--commit-after-ms N] [--quiet-ms N] [--quiet]
                                      measure a recognizer's partial cadence with real audio;
                                      P = transcriber | transcriber-fast | dictation | sfspeech
      say "<command>" [--step] [--dry-run] [--redact] [--no-cache]
      goal "<goal>" [--dry-run] [--max-steps N] [--no-escalation] [--no-intake] [--redact] [--no-cache]
                                      goal mode: observe → decide → act → verify loop with Jev's gates; the planner and
                                      writer escalate to ANTHROPIC_API_KEY's model behind a budget (Phase 6)
      goals <suite.json> [--runs N] [--only <text>] [--no-escalation]
                                      Phase 6 acceptance: every workflow and phrasing N times, evidence checked after each run
      run [--provider dictation|sfspeech] [--ui notch|pill] [--hotkey ctrl+alt+j] [--dry-run] [--speak|--no-speak] [--no-overlay] [--redact] [--no-cache] [--quiet]
                                      live voice control: notch overlay (or pill), status-bar item, spoken feedback;
                                      the hot key pauses (default ⌃⌥J), mouse to the top-left corner stops, "stop" cancels
      ui-preview [--ui notch|pill] [--out D] [--hold S]
                                      drive the overlay through scripted states and write a PNG per state
      replay runs/<ts> [--json]       re-run the policy over a run's logged answers with the current
                                      thresholds and diff the decisions (exit 2 on any change)
      trials runs/<ts> [runs/<ts2>…] [--script F]   score a live run against fixtures/trials/phase3.json (fires, false fires, latencies)
      ax [--app <name>] [--walk] [--json] [--depth N] [--max N] [--whole-app]
                                      dump an app's accessibility tree; --walk runs the perception walk,
                                      --walk --json writes a target-fixture skeleton for lab --targets
                                      run one typed command through perception, Jev, policy, executor,
                                      verification, and the run log; --step pauses before each action
      lab [--fixtures F] [--heldout H] [--cache C] [--no-live] [--installed-apps] [--targets <file|dir>]
                                      Phase 1 decision lab: every word prefix of every fixture through
                                      the questions and the policy; answers cached in C
      help

    global: --cwd <dir>             run as if started in <dir> (used by scripts/app-run.sh)
    """
}
