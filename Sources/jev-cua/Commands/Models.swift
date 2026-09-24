import Foundation
import JevCore

enum Models {
    static func run(_ args: Args) async throws {
        let client = try JevClient()
        let models = try await client.listModels()
        let w = models.map { $0.name.count }.max() ?? 10
        for m in models {
            print(m.name.padding(toLength: w, withPad: " ", startingAt: 0), m.releaseDate ?? "-", m.description, separator: "  ")
        }
        print("\npinned: \(Config.model)")
    }
}
