import Foundation

/// Anything that answers Jev questions. The live client, a fixture cache, and test mocks all
/// conform, so the session and policy never know which one they are talking to.
public protocol JevDeciding: Sendable {
    func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse
}

public enum JevError: Error, CustomStringConvertible, Sendable {
    /// The endpoint's credential (named) is not set.
    case missingAPIKey(String)
    case http(status: Int, body: String)
    case rateLimited(retryAfterMs: Int?)
    case overloaded(retryAfterMs: Int?)
    case decoding(String)
    case malformed(MalformedAnswer)
    case transport(String)
    case cancelled

    public var description: String {
        switch self {
        case .missingAPIKey(let name): "\(name) is not set (put it in .env or the environment)"
        case .http(let s, let b): "HTTP \(s): \(b.prefix(300))"
        case .rateLimited(let r): "rate limited (429), retry-after \(r.map { "\($0) ms" } ?? "unspecified")"
        case .overloaded(let r): "overloaded (529), retry-after \(r.map { "\($0) ms" } ?? "unspecified")"
        case .decoding(let m): "decoding: \(m)"
        case .malformed(let m): m.description
        case .transport(let m): "transport: \(m)"
        case .cancelled: "cancelled"
        }
    }

    /// True when Jev could not be reached or could not answer: the network, a timeout, a 5xx, an
    /// overload, rate limiting, a missing or rejected key, or (through AI Gateway) no credits or an
    /// exhausted budget. False for a bad answer or a cancelled request. The voice app shows an
    /// outage until the next answer arrives.
    public var isOutage: Bool {
        switch self {
        case .transport, .overloaded, .rateLimited, .missingAPIKey: true
        case .http(let status, _): status >= 500 || status == 401 || status == 402 || status == 403
        case .decoding, .malformed, .cancelled: false
        }
    }

    /// A few words for the overlay while offline; the full description stays in the run log.
    /// AI Gateway's spend errors carry a code in the body (its setup guide's error table).
    public var outageSummary: String {
        switch self {
        case .transport(let m): m.contains("timed out") || m.contains("-1001") ? "timed out" : "no connection"
        case .http(let s, let body):
            if body.contains("insufficient_funds") { "AI Gateway credits used up (HTTP 402)" }
            else if body.contains("quota_for_entity_exceeded") { "AI Gateway budget exhausted (HTTP 402)" }
            else if body.contains("customer_verification_required") { "AI Gateway needs a payment method (HTTP 403)" }
            else if s == 401 || s == 403 { "API key rejected (HTTP \(s))" }
            else if s == 402 { "payment required (HTTP 402)" }
            else { "server error (HTTP \(s))" }
        case .overloaded: "Jev is overloaded"
        case .rateLimited: "rate limited"
        case .missingAPIKey(let name): "\(name) missing"
        default: description
        }
    }
}

/// Direct URLSession client for POST /v1/systemone and GET /v1/models. Per-attempt timeout,
/// one retry on 429/529 honouring Retry-After, and no retry once the calling task is cancelled
/// (a superseded utterance must never spend a second request).
public final class JevClient: JevDeciding, Sendable {
    public let endpoint: JevEndpoint
    public var baseURL: URL { endpoint.baseURL }
    public var model: String { endpoint.model }
    private let apiKey: String
    private let session: URLSession
    private let maxRetryDelayMs: Int

    /// `endpoint` defaults to the configured one (`JEV_ENDPOINT`, see `JevEndpoint`); `apiKey`
    /// defaults to that endpoint's credential from the environment or `.env`.
    public init(endpoint: JevEndpoint? = nil, apiKey: String? = nil, timeout: TimeInterval = 5, maxRetryDelayMs: Int = 2000) throws {
        let endpoint = try endpoint ?? JevEndpoint.current()
        guard let key = apiKey ?? Env.secret(endpoint.keyName), !key.isEmpty else { throw JevError.missingAPIKey(endpoint.keyName) }
        self.endpoint = endpoint
        self.apiKey = key
        self.maxRetryDelayMs = maxRetryDelayMs
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpAdditionalHeaders = ["User-Agent": "jev-cua/0.1"]
        session = URLSession(configuration: cfg)
    }

    public func systemOne(state: JSONValue, questions: [String: Question], model: String? = nil) async throws -> JevResponse {
        precondition(!questions.isEmpty, "at least one question")
        let request = JevRequest(state: state, model: model ?? self.model, questions: questions)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let body = try enc.encode(request)

        var attempt = 0
        while true {
            attempt += 1
            let t0 = Mono.now()
            let (data, http) = try await post("/v1/systemone", body: body)
            let latency = (Mono.now() - t0) * 1000
            // TypeSafe names the request in a header; AI Gateway names it in the body, which is the
            // ID its Logs are searched by.
            let requestId = http.value(forHTTPHeaderField: "x-typesafe-request-id") ?? Self.gatewayGenerationId(data)

            switch http.statusCode {
            case 200..<300:
                var resp: JevResponse
                do {
                    resp = try JSONDecoder().decode(JevResponse.self, from: data)
                } catch {
                    throw JevError.decoding("\(error) in \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                }
                do {
                    try resp.validate(against: questions)
                } catch let m as MalformedAnswer {
                    throw JevError.malformed(m)
                }
                resp.latencyMs = latency
                resp.requestId = requestId
                return resp
            case 429, 529:
                let retryMs = Self.retryAfterMs(http)
                let err: JevError = http.statusCode == 429 ? .rateLimited(retryAfterMs: retryMs) : .overloaded(retryAfterMs: retryMs)
                guard attempt == 1, !Task.isCancelled else { throw err }
                let delay = min(retryMs ?? 500, maxRetryDelayMs)
                try await Task.sleep(for: .milliseconds(delay))
                if Task.isCancelled { throw JevError.cancelled }
                continue
            default:
                throw JevError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    public func listModels() async throws -> [ModelCard] {
        var req = URLRequest(url: baseURL.appending(path: "/v1/models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw JevError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw JevError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decodeModels(data)
    }

    /// TypeSafe lists `{"models": [{name, description, release_date}]}`; a list in the common
    /// `{"data": [{id, description}]}` shape is read too, so either endpoint's catalog prints.
    static func decodeModels(_ data: Data) throws -> [ModelCard] {
        struct TypeSafeList: Decodable { let models: [ModelCard] }
        if let list = try? JSONDecoder().decode(TypeSafeList.self, from: data) { return list.models }
        struct Entry: Decodable { let id: String; let description: String?; let name: String? }
        struct DataList: Decodable { let data: [Entry] }
        let list = try JSONDecoder().decode(DataList.self, from: data)
        return list.data.map { ModelCard(name: $0.id, description: $0.description ?? $0.name ?? "", releaseDate: nil) }
    }

    /// `provider_metadata.gateway.generationId` from an AI Gateway response body, if present.
    static func gatewayGenerationId(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = (root["provider_metadata"] ?? root["providerMetadata"]) as? [String: Any],
              let gateway = meta["gateway"] as? [String: Any] else { return nil }
        return gateway["generationId"] as? String
    }

    private func post(_ path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw JevError.transport("no HTTP response") }
            return (data, http)
        } catch let e as JevError {
            throw e
        } catch let e as URLError where e.code == .cancelled {
            throw JevError.cancelled
        } catch {
            throw JevError.transport(String(describing: error))
        }
    }

    static func retryAfterMs(_ http: HTTPURLResponse) -> Int? {
        if let ms = http.value(forHTTPHeaderField: "retry-after-ms"), let v = Int(ms) { return v }
        if let s = http.value(forHTTPHeaderField: "Retry-After"), let v = Double(s) { return Int(v * 1000) }
        return nil
    }
}
