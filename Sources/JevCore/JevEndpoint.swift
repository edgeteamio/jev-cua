import Foundation

/// Where Jev requests go. TypeSafe's own API is the default. Vercel AI Gateway serves the same
/// model through its TypeSafe-compatible API (vercel.com/docs/ai-gateway/sdks-and-apis/typesafe):
/// the same `POST /v1/systemone` request and the same answers under another base URL, billed and
/// logged in Vercel with the team's budgets. Only the base URL, the credential, and the model name
/// differ, so validation, the answer cache, and replay work unchanged.
///
/// Chosen by `JEV_ENDPOINT` (`typesafe` or `gateway`) from the environment or `.env`, or by the
/// `--jev-endpoint` flag.
public struct JevEndpoint: Sendable, Equatable {
    public enum Kind: String, Sendable { case typesafe, gateway }

    public var kind: Kind
    public var baseURL: URL
    /// The `model` field sent with every request.
    public var model: String
    /// The environment variable holding the credential. The value is never logged.
    public var keyName: String

    public static let typesafe = JevEndpoint(kind: .typesafe, baseURL: Config.baseURL, model: Config.model, keyName: Env.apiKeyName)

    public static let gatewayKeyName = "AI_GATEWAY_API_KEY"
    /// A Vercel deployment's (or `vercel env pull`'s) OIDC token authenticates the gateway too.
    public static let gatewayOIDCName = "VERCEL_OIDC_TOKEN"

    /// The model the thresholds were tuned on is the only one this app should run unannounced.
    /// On the direct endpoint it is pinned; through the gateway it is whatever the gateway ID
    /// resolves to, so the doctor and the run log say so.
    public var pinned: Bool { model == Config.model || model.hasSuffix("/" + Config.model) }

    /// Pure, for tests: reads `JEV_ENDPOINT`, `JEV_GATEWAY_MODEL`, and which gateway credential is
    /// set. An unknown `JEV_ENDPOINT` value is an error rather than a silent default.
    public static func from(environment env: [String: String]) throws -> JevEndpoint {
        let raw = (env["JEV_ENDPOINT"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case "", "typesafe", "direct":
            return .typesafe
        case "gateway", "vercel", "ai-gateway", "vercel-ai-gateway":
            let model = (env["JEV_GATEWAY_MODEL"] ?? "").trimmingCharacters(in: .whitespaces)
            let keyName = (env[gatewayKeyName] ?? "").isEmpty && !(env[gatewayOIDCName] ?? "").isEmpty ? gatewayOIDCName : gatewayKeyName
            return JevEndpoint(kind: .gateway, baseURL: Config.gatewayBaseURL, model: model.isEmpty ? Config.gatewayModel : model, keyName: keyName)
        default:
            throw EndpointError(value: raw)
        }
    }

    /// The endpoint for this process, after loading `.env`.
    public static func current() throws -> JevEndpoint {
        Env.loadDotEnv()
        return try from(environment: ProcessInfo.processInfo.environment)
    }

    /// One line for the doctor, the models list, and the startup banner.
    public var summary: String {
        switch kind {
        case .typesafe: "TypeSafe (\(baseURL.host ?? "?")), model \(model)"
        case .gateway: "Vercel AI Gateway (\(baseURL.host ?? "?")\(baseURL.path)), model \(model)" + (pinned ? "" : ", not pinned")
        }
    }

    public struct EndpointError: Error, CustomStringConvertible, Sendable {
        public let value: String
        public var description: String { "JEV_ENDPOINT='\(value)' is not an endpoint: use 'typesafe' (default) or 'gateway'" }
    }
}
