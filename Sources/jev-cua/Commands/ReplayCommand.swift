import Foundation
import JevCore

/// `jev-cua replay runs/<ts> [--json]`: policy over logged answers with current thresholds; exit 2 when decisions differ.
enum ReplayCommand {
    static func run(_ args: Args) async throws {
        guard let path = args.positional.first else { throw UsageError("usage: jev-cua replay runs/<ts>") }
        let dir = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let report = try Replay.run(directory: dir)
        if args.flag("json") {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(report), encoding: .utf8)!)
        } else {
            print(Replay.render(report))
        }
        if report.changed > 0 { fflush(stdout); exit(2) }
    }
}
