import Foundation

/// Monotonic seconds since boot. Every timestamp in a contract or run log uses this clock,
/// never wall-clock time, so intervals survive clock adjustments and replays line up.
public enum Mono {
    public static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum Ident {
    /// Short unique id for snapshots, dispatches, and utterances.
    public static func make(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.lowercased().prefix(8)
    }
}
