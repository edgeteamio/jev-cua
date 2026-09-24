import Foundation
import JevCore

/// `jev-cua trials runs/<ts> [runs/<ts2> ...] [--script fixtures/trials/phase3.json]`
/// Several run folders are read in order (a relaunch mid-sequence splits the log).
enum TrialsCommand {
    static func run(_ args: Args) async throws {
        guard !args.positional.isEmpty else { throw UsageError("usage: jev-cua trials runs/<ts> [runs/<ts2> ...] [--script F]") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dirs = args.positional.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        let scriptURL = cwd.appending(path: args.string("script") ?? "fixtures/trials/phase3.json")
        let script = try JSONDecoder().decode(Trials.Script.self, from: Data(contentsOf: scriptURL))
        var events: [RunLog.Event] = []
        for dir in dirs {
            let text = try String(contentsOf: dir.appending(path: "events.jsonl"), encoding: .utf8)
            for line in text.split(separator: "\n") {
                // Tolerate a line holding two objects (a pre-fix interleaved write).
                var rest = Substring(line)
                while let close = rest.firstIndex(of: "}"), !rest.isEmpty {
                    var end = close
                    var depth = 0
                    var found = false
                    for (i, ch) in rest.enumerated() {
                        if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1; if depth == 0 { end = rest.index(rest.startIndex, offsetBy: i); found = true; break } }
                    }
                    guard found else { break }
                    if let ev = try? JSONDecoder().decode(RunLog.Event.self, from: Data(rest[...end].utf8)) { events.append(ev) }
                    rest = rest[rest.index(after: end)...]
                }
            }
        }
        let report = Trials.score(script: script, events: events)
        print(Trials.render(report))
        let out = dirs.last!.appending(path: "trials.md")
        try ("# Trials for \(dirs.map(\.lastPathComponent).joined(separator: " + "))\n\n```\n" + Trials.render(report) + "```\n").write(to: out, atomically: true, encoding: .utf8)
        print("wrote \(out.path)")
    }
}
