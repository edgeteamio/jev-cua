import Foundation
import os

/// Caches Jev answers by request hash (which includes the model and the exact questions, so a
/// changed question or a model move never replays a stale answer). Without a live client it is
/// cache-only and throws on a miss.
public final class JevCache: JevDeciding, @unchecked Sendable {
    /// The committed cache: answers for the lab fixtures only, safe to publish. Live commands
    /// never write here.
    public static func committedPath(_ cwd: URL) -> URL { cwd.appending(path: "fixtures/jev_cache.json") }
    /// The live cache for `say`, `run`, the suites, and `goal`: their option texts carry real
    /// transcripts and this machine's app names, so it lives under the ignored `runs/`.
    public static func livePath(_ cwd: URL) -> URL { cwd.appending(path: "runs/jev_cache.live.json") }

    public struct Entry: Codable, Sendable { public var response: JevResponse; public var savedAt: String }

    private let path: URL
    private let live: (any JevDeciding)?
    private let lock = OSAllocatedUnfairLock(uncheckedState: (entries: [String: Entry](), dirty: 0, hits: 0, misses: 0))

    public init(path: URL, live: (any JevDeciding)?) {
        self.path = path
        self.live = live
        if let data = try? Data(contentsOf: path), let e = try? JSONDecoder().decode([String: Entry].self, from: data) {
            lock.withLockUnchecked { $0.entries = e }
        }
    }

    public var stats: (entries: Int, hits: Int, misses: Int) {
        lock.withLockUnchecked { ($0.entries.count, $0.hits, $0.misses) }
    }

    public func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse {
        let key = JevRequest(state: state, model: model ?? Config.model, questions: questions).cacheKey()
        if let hit = lock.withLockUnchecked({ s -> Entry? in
            if let e = s.entries[key] { s.hits += 1; return e }
            s.misses += 1; return nil
        }) {
            var r = hit.response
            r.latencyMs = 0
            return r
        }
        guard let live else { throw JevError.transport("cache miss and no live client (key \(key.prefix(12)))") }
        let resp = try await live.systemOne(state: state, questions: questions, model: model)
        try resp.validate(against: questions)
        let shouldSave = lock.withLockUnchecked { s -> Bool in
            s.entries[key] = Entry(response: resp, savedAt: ISO8601DateFormatter().string(from: Date()))
            s.dirty += 1
            return s.dirty >= 10
        }
        if shouldSave { try? save() }
        return resp
    }

    public func save() throws {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = lock.withLockUnchecked { s -> [String: Entry] in s.dirty = 0; return s.entries }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(entries).write(to: path, options: .atomic)
    }
}
