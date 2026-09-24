import Foundation

/// Loads KEY=VALUE pairs from a dotenv file into the process environment without overriding
/// values already set. The file is looked up in the working directory and its parents so the
/// app finds it whether launched from the package root, the bundle, or a subdirectory.
public enum Env {
    public static let apiKeyName = "TYPESAFE_API_KEY"
    public static let dotenvName = ".env"

    /// The path that was loaded, if any. Set once per process.
    nonisolated(unsafe) private static var loadedFrom: URL?

    @discardableResult
    public static func loadDotEnv(startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                                  maxDepth: Int = 6) -> URL? {
        if let loadedFrom { return loadedFrom }
        var candidates: [URL] = []
        if let home = ProcessInfo.processInfo.environment["JEV_CUA_HOME"] {
            candidates.append(URL(fileURLWithPath: home).appending(path: dotenvName))
        }
        var dir = start.standardizedFileURL
        for _ in 0..<maxDepth {
            candidates.append(dir.appending(path: dotenvName))
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // A bundle launched with `open` has cwd "/"; also try next to the .app.
        let exe = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(exe.appending(path: dotenvName))
        candidates.append(exe.deletingLastPathComponent().appending(path: dotenvName))

        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (k, v) in parse(text) where ProcessInfo.processInfo.environment[k] == nil {
                setenv(k, v, 0)
            }
            loadedFrom = url
            return url
        }
        return nil
    }

    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.firstIndex(of: "#"), value[value.index(before: hash)] == " " {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            out[key] = value
        }
        return out
    }

    /// The API key from the environment, after loading dotenv. Never log this.
    public static var apiKey: String? {
        loadDotEnv()
        return ProcessInfo.processInfo.environment[apiKeyName]
    }

    public static var apiKeyPresent: Bool { !(apiKey ?? "").isEmpty }

    /// Any other secret from the environment after loading dotenv (escalation providers). Never log it.
    public static func secret(_ name: String) -> String? {
        loadDotEnv()
        let v = ProcessInfo.processInfo.environment[name] ?? ""
        return v.isEmpty ? nil : v
    }
    public static var dotenvPath: URL? { loadDotEnv() }
}
