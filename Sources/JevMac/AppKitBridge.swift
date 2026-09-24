import AppKit
import Foundation

/// Small AppKit lookups exposed to the CLI target.
public enum AppKitBridge {
    public static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.localizedName }
    }
}
