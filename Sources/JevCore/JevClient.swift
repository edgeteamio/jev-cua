import Foundation

/// Anything that answers Jev questions. The live client, a fixture cache, and test mocks all
/// conform, so the session and policy never know which one they are talking to.
public protocol JevDeciding: Sendable {
    func systemOne(state: JSONValue, questions: [String: Question], model: String?) async throws -> JevResponse
}

public enum JevError: Error, CustomStringConvertible, Sendable {
    case missingAPIKey
    case http(status: Int, body: String)
    case rateLimited(retryAfterMs: Int?)
    case overloaded(retryAfterMs: Int?)
    case decoding(String)
    case malformed(MalformedAnswer)
    case transport(String)
    case cancelled

    public var description: String {
        switch self {
        case .missingAPIKey: "TYPESAFE_API_KEY is not set (put it in .env or the environment)"
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
    /// overload, rate limiting, a missing key. False for a bad answer or a cancelled request. The
    /// voice app shows an outage until the next answer arrives.
    public var isOutage: Bool {
        switch self {
        case .transport, .overloaded, .rateLimited, .missingAPIKey: true
        case .http(let status, _): status >= 500 || status == 401 || status == 403
        case .decoding, .malformed, .cancelled: false
        }
    }

    /// A few words for the overlay while offline; the full description stays in the run log.
    public var outageSummary: String {
        switch self {
        case .transport(let m): m.contains("timed out") || m.contains("-1001") ? "timed out" : "no connection"
        case .http(let s, _): s == 401 || s == 403 ? "API key rejected (HTTP \(s))" : "server error (HTTP \(s))"
        case .overloaded: "Jev is overloaded"
        case .rateLimited: "rate limited"
        case .missingAPIKey: "no API key"
        default: description
        }
    }
}

/// Direct URLSession client for POST /v1/systemone and GET /v1/models. Per-attempt timeout,
/// one retry on 429/529 honouring Retry-After, and no retry once the calling task is cancelled
/// (a superseded utterance must never spend a second request).
public final class JevClient: JevDeciding, Sendable {
    public let baseURL: URL
    public let model: String
    private let apiKey: String
    private let session: URLSession
    private let maxRetryDelayMs: Int

    public init(apiKey: String? = nil, baseURL: URL = Config.baseURL, model: String = Config.model,
                timeout: TimeInterval = 5, maxRetryDelayMs: Int = 2000) throws {
        guard let key = apiKey ?? Env.apiKey, !key.isEmpty else { throw JevError.missingAPIKey }
        self.apiKey = key
        self.baseURL = baseURL
        self.model = model
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
            let requestId = http.value(forHTTPHeaderField: "x-typesafe-request-id")

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
        struct Wrapper: Decodable { let models: [ModelCard] }
        return try JSONDecoder().decode(Wrapper.self, from: data).models
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
