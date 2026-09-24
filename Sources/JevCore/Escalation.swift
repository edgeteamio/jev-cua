import Foundation

/// Stronger model behind the Anthropic Messages API, for generation only (plan Phase 6):
/// planning subgoals, drafting field text, composing an answer. Jev still decides every action.
/// Every reply must be a JSON object with the agreed keys or it is discarded. Needs
/// `ANTHROPIC_API_KEY` in the environment or `.env`; absent, the runner has no escalation.
public final class AnthropicEscalation: Escalating, @unchecked Sendable {
    public let name: String
    private let model: String
    private let key: String
    private let session: URLSession
    public static let defaultModel = "claude-haiku-4-5-20251001"
    public static let keyName = "ANTHROPIC_API_KEY"

    public init?(model: String = AnthropicEscalation.defaultModel) {
        guard let k = Env.secret(Self.keyName) else { return nil }
        key = k; self.model = model; name = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    public static var available: Bool { Env.secret(keyName) != nil }

    public func plan(goal: String) async throws -> [String] {
        let system = """
        You split a Mac user's spoken goal into 2 to 5 ordered subgoals that a voice assistant can carry out with these actions only: \
        open an app, open a site, web search (google, youtube, wikipedia, github, reddit), create a note, type text into the focused field, \
        click a labelled control, press enter or escape, scroll, go back. Each subgoal is one short imperative sentence and ends with \
        "(done when: <observable evidence>)". Reply with a JSON object with exactly one key "subgoals", an array of strings. No prose.
        """
        let obj = try await call(system: system, user: "Goal: \(goal)")
        guard let arr = obj["subgoals"]?.arrayValue else { throw EscalationError.badReply("no subgoals array") }
        return arr.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func write(goal: String, field: FocusedField?, app: String, history: [String]) async throws -> String? {
        let system = """
        You draft the exact text a voice assistant should type into the focused field of a Mac app to carry out the user's goal. \
        Write only what belongs in the field: plain text, no markdown, no quotes around it, no explanation. Match the field's purpose \
        (a note body gets the note; a search box gets a query; a title field gets a title). Reply with a JSON object with exactly one key "text". \
        If nothing should be typed, reply {"text": ""}.
        """
        var user = "Goal: \(goal)\nApp: \(app)\n"
        if let f = field { user += "Field: \(f.role)\(f.label.map { " labelled '\($0)'" } ?? "")\(f.placeholder.map { " placeholder '\($0)'" } ?? "")\(f.valuePreview.map { " currently '\($0)'" } ?? "")\n" }
        if !history.isEmpty { user += "Done so far: \(history.joined(separator: "; "))\n" }
        let obj = try await call(system: system, user: user)
        guard obj.objectValue?.count == 1, let text = obj["text"]?.stringValue else { throw EscalationError.badReply("reply is not exactly {\"text\"}") }
        return text.isEmpty ? nil : text
    }

    public func compose(goal: String, observations: [String], history: [String]) async throws -> String? {
        let system = """
        The user asked a question; a voice assistant searched and observed the screens below. Answer the question in one or two plain \
        sentences using only what the observations show. If they do not contain the answer, say so in one sentence. \
        Reply with a JSON object with exactly one key "answer".
        """
        let user = "Question: \(goal)\nObservations:\n" + observations.joined(separator: "\n") + "\nActions: " + history.joined(separator: "; ")
        let obj = try await call(system: system, user: user)
        return obj["answer"]?.stringValue
    }

    // MARK: API

    private func call(system: String, user: String) async throws -> JSONValue {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: JSONValue = ["model": .string(model), "max_tokens": 400, "system": .string(system),
                               "messages": [["role": "user", "content": .string(user)]]]
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EscalationError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let text = json["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
        // The reply must be one JSON object; tolerate a fenced block around it.
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") { s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { throw EscalationError.badReply("no JSON object") }
        return try JSONDecoder().decode(JSONValue.self, from: Data(s[start...end].utf8))
    }
}

public enum EscalationError: Error, CustomStringConvertible {
    case http(Int)
    case badReply(String)
    public var description: String {
        switch self {
        case .http(let c): return "escalation HTTP \(c)"
        case .badReply(let m): return "escalation reply rejected: \(m)"
        }
    }
}
