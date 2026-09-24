import Foundation

// Wire types for POST /v1/systemone (docs.typesafe.ai/api). Questions encode to the API's
// {type, instructions, criteria} shape; answers decode by their `type` discriminator.

// MARK: - Questions

public struct NoulQuestion: Sendable, Equatable, Codable {
    public var instructions: JSONValue
    public var trueCriteria: JSONValue?
    public var falseCriteria: JSONValue?
    public init(_ instructions: JSONValue, true t: JSONValue? = nil, false f: JSONValue? = nil) {
        self.instructions = instructions; trueCriteria = t; falseCriteria = f
    }
}

public struct ChoiceQuestion: Sendable, Equatable, Codable {
    public var instructions: JSONValue
    /// Option id -> description (or null). At most 255 options.
    public var criteria: [String: JSONValue]
    public init(_ instructions: JSONValue, criteria: [String: JSONValue]) {
        self.instructions = instructions; self.criteria = criteria
    }
}

public struct ScoreQuestion: Sendable, Equatable, Codable {
    public var instructions: JSONValue
    /// Ordered level descriptions, index 0 first. At least two.
    public var criteria: [JSONValue]
    public init(_ instructions: JSONValue, levels: [JSONValue]) {
        self.instructions = instructions; criteria = levels
    }
}

public enum Question: Sendable, Equatable {
    case noul(NoulQuestion)
    case choice(ChoiceQuestion)
    case score(ScoreQuestion)

    public static func noul(_ instructions: JSONValue, true t: JSONValue? = nil, false f: JSONValue? = nil) -> Question {
        .noul(NoulQuestion(instructions, true: t, false: f))
    }
    public static func choice(_ instructions: JSONValue, _ criteria: [String: JSONValue]) -> Question {
        .choice(ChoiceQuestion(instructions, criteria: criteria))
    }
    public static func score(_ instructions: JSONValue, _ levels: [JSONValue]) -> Question {
        .score(ScoreQuestion(instructions, levels: levels))
    }

    public var typeName: String {
        switch self {
        case .noul: "noul"
        case .choice: "choice"
        case .score: "score"
        }
    }
}

extension Question: Codable {
    private enum Keys: String, CodingKey { case type, instructions, criteria }
    private enum NoulKeys: String, CodingKey { case `true`, `false` }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .noul(let q):
            try c.encode(q.instructions, forKey: .instructions)
            if q.trueCriteria != nil || q.falseCriteria != nil {
                var n = c.nestedContainer(keyedBy: NoulKeys.self, forKey: .criteria)
                try n.encodeIfPresent(q.trueCriteria, forKey: .true)
                try n.encodeIfPresent(q.falseCriteria, forKey: .false)
            }
        case .choice(let q):
            try c.encode(q.instructions, forKey: .instructions)
            try c.encode(q.criteria, forKey: .criteria)
        case .score(let q):
            try c.encode(q.instructions, forKey: .instructions)
            try c.encode(q.criteria, forKey: .criteria)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        let instructions = try c.decodeIfPresent(JSONValue.self, forKey: .instructions) ?? .null
        switch type {
        case "noul":
            var t: JSONValue? = nil, f: JSONValue? = nil
            if c.contains(.criteria), let n = try? c.nestedContainer(keyedBy: NoulKeys.self, forKey: .criteria) {
                t = try n.decodeIfPresent(JSONValue.self, forKey: .true)
                f = try n.decodeIfPresent(JSONValue.self, forKey: .false)
            }
            self = .noul(NoulQuestion(instructions, true: t, false: f))
        case "choice":
            self = .choice(ChoiceQuestion(instructions, criteria: try c.decode([String: JSONValue].self, forKey: .criteria)))
        case "score":
            self = .score(ScoreQuestion(instructions, levels: try c.decode([JSONValue].self, forKey: .criteria)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown question type \(type)")
        }
    }
}

// MARK: - Answers

public struct ChoiceAnswer: Codable, Sendable, Equatable {
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double
    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice; self.probabilities = probabilities; self.confidence = confidence
    }
    /// Options by probability, highest first, excluding `excluding`.
    public func ranked(excluding: Set<String> = []) -> [(id: String, p: Double)] {
        probabilities.filter { !excluding.contains($0.key) }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

public struct ScoreAnswer: Codable, Sendable, Equatable {
    public var score: Double
    public var legend: [String: JSONValue]?
    public var probabilities: [String: Double]
    public var confidence: Double
    public init(score: Double, legend: [String: JSONValue]? = nil, probabilities: [String: Double] = [:], confidence: Double) {
        self.score = score; self.legend = legend; self.probabilities = probabilities; self.confidence = confidence
    }
    private enum Keys: String, CodingKey { case score, legend, probabilities, confidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        score = try c.decode(Double.self, forKey: .score)
        legend = try c.decodeIfPresent([String: JSONValue].self, forKey: .legend)
        probabilities = try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
        confidence = try c.decode(Double.self, forKey: .confidence)
    }
}

public enum Answer: Sendable, Equatable {
    case noul(Double)
    case choice(ChoiceAnswer)
    case score(ScoreAnswer)

    public var noul: Double? { if case .noul(let p) = self { return p } else { return nil } }
    public var choice: ChoiceAnswer? { if case .choice(let a) = self { return a } else { return nil } }
    public var score: ScoreAnswer? { if case .score(let a) = self { return a } else { return nil } }
}

extension Answer: Codable {
    private enum Keys: String, CodingKey { case type, noul }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "noul": self = .noul(try c.decode(Double.self, forKey: .noul))
        case "choice": self = .choice(try ChoiceAnswer(from: decoder))
        case "score": self = .score(try ScoreAnswer(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown answer type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .noul(let p):
            try c.encode("noul", forKey: .type)
            try c.encode(p, forKey: .noul)
        case .choice(let a):
            try c.encode("choice", forKey: .type)
            try a.encode(to: encoder)
        case .score(let a):
            try c.encode("score", forKey: .type)
            try a.encode(to: encoder)
        }
    }
}

// MARK: - Request and response

public struct JevRequest: Encodable, Sendable {
    public var state: JSONValue
    public var model: String
    public var questions: [String: Question]
    public init(state: JSONValue, model: String, questions: [String: Question]) {
        self.state = state; self.model = model; self.questions = questions
    }
    /// Stable hash of the whole request, used as the lab cache key. Includes the model, so a
    /// model move invalidates cached answers.
    public func cacheKey() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(self)) ?? Data()
        return SHA.hex(data)
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
    private enum Keys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
    }
    public var costUSD: Double { Double(inputTokens) / 1_000_000 * Config.pricePerMillionInputTokensUSD }
}

public struct JevResponse: Codable, Sendable, Equatable {
    public var model: String
    public var answers: [String: Answer]
    public var usage: Usage
    /// Client-measured, not part of the API body.
    public var latencyMs: Double
    public var requestId: String?

    private enum Keys: String, CodingKey { case model, answers, usage, latencyMs, requestId }
    public init(model: String, answers: [String: Answer], usage: Usage, latencyMs: Double, requestId: String?) {
        self.model = model; self.answers = answers; self.usage = usage; self.latencyMs = latencyMs; self.requestId = requestId
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        model = try c.decode(String.self, forKey: .model)
        answers = try c.decode([String: Answer].self, forKey: .answers)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage) ?? Usage(inputTokens: 0, outputTokens: 0)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }
}

// MARK: - Answer validation (plan section 4; jev-ultrafast's validate_choice)

public struct MalformedAnswer: Error, CustomStringConvertible, Sendable, Equatable {
    public let question: String
    public let reason: String
    public var description: String { "malformed answer for `\(question)`: \(reason)" }
}

extension JevResponse {
    /// Checks every answer against the question that produced it. A Choice must name a known
    /// option, carry a probability for every option and nothing else, sum to 1 within 0.02, and
    /// report the argmax as its choice; a Noul must be finite in 0...1; a Score's probability
    /// keys must be level indices. Any failure makes the whole response unusable.
    public func validate(against questions: [String: Question]) throws {
        func unit(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= 1 }
        for (id, question) in questions {
            guard let answer = answers[id] else { throw MalformedAnswer(question: id, reason: "missing") }
            switch (question, answer) {
            case (.noul, .noul(let p)):
                guard unit(p) else { throw MalformedAnswer(question: id, reason: "noul \(p) outside 0...1") }
            case (.choice(let q), .choice(let a)):
                let options = Set(q.criteria.keys)
                guard options.contains(a.choice) else { throw MalformedAnswer(question: id, reason: "choice '\(a.choice)' is not an option") }
                guard Set(a.probabilities.keys) == options else { throw MalformedAnswer(question: id, reason: "probability keys do not match the options") }
                guard a.probabilities.values.allSatisfy(unit), unit(a.confidence) else { throw MalformedAnswer(question: id, reason: "probability or confidence outside 0...1") }
                let sum = a.probabilities.values.reduce(0, +)
                guard abs(sum - 1) <= 0.02 else { throw MalformedAnswer(question: id, reason: "probabilities sum to \(sum)") }
                let top = a.probabilities.values.max() ?? 0
                guard (a.probabilities[a.choice] ?? -1) >= top - 1e-6 else {
                    let best = a.probabilities.max { $0.value < $1.value }
                    throw MalformedAnswer(question: id, reason: "choice '\(a.choice)' p=\(a.probabilities[a.choice] ?? -1) is not the argmax ('\(best?.key ?? "?")' p=\(best?.value ?? -1), confidence \(a.confidence))")
                }
            case (.score(let q), .score(let a)):
                let levels = Set((0..<q.criteria.count).map(String.init))
                guard Set(a.probabilities.keys).isSubset(of: levels) else { throw MalformedAnswer(question: id, reason: "probability keys are not level indices") }
                guard a.probabilities.values.allSatisfy(unit), unit(a.confidence), a.score.isFinite else { throw MalformedAnswer(question: id, reason: "value outside range") }
                if !a.probabilities.isEmpty {
                    let sum = a.probabilities.values.reduce(0, +)
                    guard abs(sum - 1) <= 0.02 else { throw MalformedAnswer(question: id, reason: "probabilities sum to \(sum)") }
                }
            default:
                throw MalformedAnswer(question: id, reason: "answer type does not match question type \(question.typeName)")
            }
        }
    }
}

public struct ModelCard: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var releaseDate: String?
    private enum CodingKeys: String, CodingKey { case name, description, releaseDate = "release_date" }
}

// MARK: - SHA-256 without CryptoKit (keeps JevCore free of platform frameworks)

enum SHA {
    static func hex(_ data: Data) -> String {
        // FNV-1a 64 folded twice is enough for a local cache key; it is not a security hash.
        // Two passes with different seeds give 128 bits, which avoids accidental collisions
        // across thousands of fixture prefixes.
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        return String(format: "%016llx%016llx", fnv(0xcbf29ce484222325), fnv(0x84222325cbf29ce4))
    }
}
