import Foundation

/// A verbatim candidate span of the unconsumed raw transcript. Jev only ever picks one of
/// these; code copies the text unchanged.
public struct SpanCandidate: Sendable, Equatable, Hashable, Codable {
    public let text: String
    /// Token range into `Transcript.tokens(raw)` of the unconsumed transcript.
    public let range: Range<Int>
    public init(text: String, range: Range<Int>) { self.text = text; self.range = range }
}

public struct SpanSet: Sendable, Equatable, Codable {
    public var payload: [SpanCandidate]
    public var urls: [SpanCandidate]
    public static let empty = SpanSet(payload: [], urls: [])
    public init(payload: [SpanCandidate], urls: [SpanCandidate]) { self.payload = payload; self.urls = urls }

    public func payload(text: String) -> SpanCandidate? { payload.first { $0.text == text } }
    public func url(text: String) -> SpanCandidate? { urls.first { $0.text == text } }
}

/// Pure code (plan section 8; ported from moritzkremb/jev-voice-browser src/spans.js and
/// timpratim/macbrow router._span_candidates). Tuned to over-find; Jev decides.
public enum Spans {
    /// Trigger phrases whose remainder is a payload candidate. Longest first so "make the title
    /// say" wins over "say".
    public static let triggers: [String] = [
        "make the title say", "make the heading say", "search wikipedia for", "search youtube for", "search google for", "google search",
        "search for", "look up", "pull up", "jot down", "write down", "note down", "remind me to", "find me", "show me", "tell me", "fill in",
        "title it", "call it", "name it", "type in", "search", "google", "youtube", "wikipedia", "type", "write", "find", "play", "check", "with",
        "enter", "say", "titled",
    ]

    public static let fillers: [String] = ["please", "for me", "okay", "thanks", "thank you", "now", "for me please", "in it", "into it", "in there", "in the note", "in the field", "there",
                                           "as the body", "as the content", "as the text", "as the title", "as the note"]

    static let tlds = ["com", "org", "net", "io", "ai", "co", "dev", "edu", "gov", "app"]

    public static func extract(from raw: String, cap: Int = 32) -> SpanSet {
        let rawTokens = Transcript.tokens(raw)
        let norm = rawTokens.map(Transcript.normalizeToken)
        guard !rawTokens.isEmpty else { return .empty }

        var seen = Set<String>()
        var out: [SpanCandidate] = []
        func add(_ range: Range<Int>) {
            guard !range.isEmpty, range.upperBound <= rawTokens.count else { return }
            var text = rawTokens[range].joined(separator: " ")
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”"))
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return }
            out.append(SpanCandidate(text: text, range: range))
        }

        // 1. Trigger remainders, plus a trailing-filler variant of each.
        for trigger in triggers {
            let tw = trigger.split(separator: " ").map(String.init)
            var i = 0
            while i + tw.count <= norm.count {
                if Array(norm[i..<i + tw.count]) == tw, i + tw.count < norm.count {
                    let start = i + tw.count
                    // Filler-stripped first: it is the better default when code must pick.
                    if let stripped = withoutTrailingFiller(norm, start..<rawTokens.count) { add(stripped) }
                    add(start..<rawTokens.count)
                }
                i += 1
            }
        }
        // 1b. Capitalized runs inside the sentence ("Ada", "Norbert Wiener"): names are payloads.
        var i2 = 0
        while i2 < rawTokens.count {
            let isCap = rawTokens[i2].first?.isUppercase == true && i2 > 0
            if isCap {
                var j = i2
                while j + 1 < rawTokens.count, rawTokens[j + 1].first?.isUppercase == true { j += 1 }
                add(i2..<j + 1)
                i2 = j + 1
            } else { i2 += 1 }
        }
        // 2. Suffixes, longest first.
        for start in 0..<rawTokens.count where out.count < cap { add(start..<rawTokens.count) }
        // 3. Inner spans by decreasing length.
        var length = rawTokens.count - 1
        while length >= 1, out.count < cap {
            var start = 0
            while start + length < rawTokens.count, out.count < cap {
                add(start..<start + length)
                start += 1
            }
            length -= 1
        }
        if out.count > cap { out = Array(out[0..<cap]) }

        // URL spans: "<word> dot <tld>", "<word> dotcom", "<word>.<tld>".
        var urls: [SpanCandidate] = []
        var seenURL = Set<String>()
        for i in rawTokens.indices {
            var range: Range<Int>? = nil
            if i + 2 < rawTokens.count, norm[i + 1] == "dot", tlds.contains(norm[i + 2]) { range = i..<i + 3 }
            else if i + 1 < rawTokens.count, norm[i + 1].hasPrefix("dot"), tlds.contains(String(norm[i + 1].dropFirst(3))) { range = i..<i + 2 }
            else if let dot = norm[i].lastIndex(of: "."), tlds.contains(String(norm[i][norm[i].index(after: dot)...])),
                    norm[i].distance(from: norm[i].startIndex, to: dot) > 0 { range = i..<i + 1 }
            if let range, toHttpURL(rawTokens[range].joined(separator: " ")) != nil {
                let text = rawTokens[range].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if seenURL.insert(text.lowercased()).inserted { urls.append(SpanCandidate(text: text, range: range)) }
            }
        }
        return SpanSet(payload: out, urls: urls)
    }

    static func withoutTrailingFiller(_ norm: [String], _ range: Range<Int>) -> Range<Int>? {
        var end = range.upperBound
        var changed = false
        var again = true
        while again {
            again = false
            for filler in fillers.sorted { $0.count > $1.count } {
                let fw = filler.split(separator: " ").map(String.init)
                if end - fw.count > range.lowerBound, Array(norm[end - fw.count..<end]) == fw {
                    end -= fw.count; changed = true; again = true; break
                }
            }
        }
        return changed ? range.lowerBound..<end : nil
    }

    /// "x dot com" → "https://x.com/". Also accepts "x.com" and "x dotcom".
    public static func toHttpURL(_ spoken: String) -> String? {
        var s = spoken.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"\s+dot\s*"#, with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+slash\s+"#, with: "/", options: .regularExpression)
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard let host = s.split(separator: "/").first, host.contains(".") else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tlds.contains(String(tld)),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        return "https://" + s + (s.contains("/") ? "" : "/")
    }

    /// "one".."nine", "first".."ninth", digits, and ordinal digits ("1st") → 1...9.
    /// A spoken repetition count: "three times", "3 times", "twice". Only the explicit forms;
    /// a bare number may be an ordinal ("tab 3") or dictation, so it is not a count. 2...20.
    public static func repetitions(in raw: String) -> Int? {
        let words = Transcript.normalize(raw).split(separator: " ").map(String.init)
        for (i, w) in words.enumerated() {
            if w == "twice" { return 2 }
            if w == "times" || w == "x", i > 0, let n = Spans.numberWord(words[i - 1]) ?? Int(words[i - 1]) ?? ["ten": 10, "fifteen": 15, "twenty": 20][words[i - 1]], (2...20).contains(n) { return n }
        }
        return nil
    }

    public static func numberWord(_ raw: String) -> Int? {
        let s = Transcript.normalizeToken(raw)
        let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        if let i = cardinals.firstIndex(of: s) { return i + 1 }
        if let i = ordinals.firstIndex(of: s) { return i + 1 }
        let digits = s.prefix { $0.isNumber }
        if let n = Int(digits), (1...9).contains(n), s.dropFirst(digits.count).allSatisfy({ ["st", "nd", "rd", "th"].contains(String($0)) || true }) { return n }
        return nil
    }

    /// The whole utterance is a stop word: handled in code before any model call.
    public static func isKillPhrase(_ raw: String) -> Bool {
        ["stop", "cancel", "never mind", "nevermind", "stop listening"].contains(Transcript.normalize(raw))
    }
}
