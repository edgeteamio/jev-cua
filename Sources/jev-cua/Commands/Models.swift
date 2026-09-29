import Foundation
import JevCore

enum Models {
    static func run(_ args: Args) async throws {
        let client = try JevClient()
        print("endpoint: \(client.endpoint.summary)\n")
        let models = try await client.listModels()
        let w = models.map { $0.name.count }.max() ?? 10
        for m in models {
            print(m.name.padding(toLength: w, withPad: " ", startingAt: 0), m.releaseDate ?? "-", m.description, separator: "  ")
        }
        print("\nrequests send: \(client.model)" + (client.endpoint.pinned ? "" : " (not pinned; thresholds were tuned on \(Config.model))"))
    }
}
