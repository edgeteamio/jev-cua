import Foundation
import JevCore

/// `jev-cua lab [--fixtures F] [--heldout H] [--cache C] [--no-live] [--installed-apps]`
enum Lab {
    static func run(_ args: Args) async throws {
        if args.string("dictation") != nil { try await DictationLab.run(args); return }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        // An absolute path stays absolute (appending one to the cwd nested it inside the repo).
        func path(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appending(path: p) }
        let fixturesPath = path(args.string("fixtures") ?? "fixtures/utterances.calibration.json")
        let heldoutPath = args.string("heldout").map(path)
        let cachePath = path(args.string("cache") ?? "fixtures/jev_cache.json")
        let live: (any JevDeciding)? = args.flag("no-live") ? nil : try JevClient()
        let cache = JevCache(path: cachePath, live: live)
        let installed = args.flag("installed-apps") ? InstalledApps.names() : []

        let runner = LabRunner(decider: cache, installedApps: installed) { line in
            FileHandle.standardError.write(Data(("  " + line + "\n").utf8))
        }
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let runs = cwd.appending(path: "runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        if let targets = args.string("targets") {
            // Phase 4 target lab: one or more capture files (comma-separated or a directory).
            var files: [URL] = []
            for part in targets.split(separator: ",").map(String.init) {
                let u = cwd.appending(path: part)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    files += ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
                } else { files.append(u) }
            }
            var totalCorrect = 0, totalRows = 0, totalCovered = 0
            for file in files {
                let f = try TargetFixture.load(file)
                let report = try await runner.runTargets(f)
                try cache.save()
                print(LabRender.targetsText(report))
                let out = runs.appending(path: "lab-targets-\(f.app.lowercased().replacingOccurrences(of: " ", with: "-"))-\(ts).md")
                try LabRender.targetsMarkdown(report).write(to: out, atomically: true, encoding: .utf8)
                totalCorrect += report.correct; totalRows += report.rows.count; totalCovered += report.covered
            }
            print("targets total: \(totalCorrect)/\(totalRows) correct, coverage \(totalCovered)/\(totalRows)")
            return
        }

        // Which endpoint answered is part of the result: two routes serve Jev (JEV_ENDPOINT).
        let endpoint = (live as? JevClient)?.endpoint.summary ?? "cache only (--no-live)"
        var reports: [(String, LabReport)] = []
        let cal = try Fixtures.load(fixturesPath)
        var calReport = try await runner.run(cal, name: "calibration")
        calReport.summary.endpoint = endpoint
        reports.append(("calibration", calReport))
        try cache.save()
        if let heldoutPath {
            let held = try Fixtures.load(heldoutPath)
            var heldReport = try await runner.run(held, name: "heldout")
            heldReport.summary.endpoint = endpoint
            reports.append(("heldout", heldReport))
            try cache.save()
        }

        for (name, report) in reports {
            print(LabRender.summaryText(report.summary))
            let out = runs.appending(path: "lab-\(name)-\(ts).md")
            try LabRender.markdown(report).write(to: out, atomically: true, encoding: .utf8)
            let json = runs.appending(path: "lab-\(name)-\(ts).json")
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(report).write(to: json)
            print("  wrote \(out.lastPathComponent) and .json\n")
        }
        let s = cache.stats
        print("cache: \(s.entries) entries, \(s.hits) hits, \(s.misses) misses (\(cachePath.lastPathComponent))")
    }
}

/// Names of installed applications, for the dynamic `app` options (macbrow's `apps` source).
enum InstalledApps {
    static func names() -> [String] {
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var out: [String] = []
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") { out.append(String(item.dropLast(4))) }
        }
        return Array(Set(out)).sorted()
    }
}
