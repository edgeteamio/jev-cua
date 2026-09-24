import Foundation

/// Transcript views. The raw recognizer text is never modified; spans index into it. The
/// normalized view (lowercase, punctuation stripped) is what the `transcript` state field and
/// the prefix matching use.
public enum Transcript {
    /// Lowercase, keep letters, digits, apostrophes, and spaces; collapse whitespace; keep the
    /// last `maxChars` at a word boundary.
    public static func normalize(_ raw: String, maxChars: Int = Config.maxTranscriptChars) -> String {
        let words = tokens(raw).map(normalizeToken).filter { !$0.isEmpty }
        var out = words.joined(separator: " ")
        if out.count > maxChars {
            var kept: [String] = []
            var length = 0
            for w in words.reversed() {
                if length + w.count + 1 > maxChars { break }
                kept.append(w); length += w.count + 1
            }
            out = kept.reversed().joined(separator: " ")
        }
        return out
    }

    /// Whitespace-separated raw tokens, in order. A verb glued to a domain by the recognizer
    /// ("openx.com", seen from DictationTranscriber on 2026-09-20) is split into two tokens.
    public static func tokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).flatMap { splitGluedDomain(String($0)) }
    }

    static let gluedVerbs = ["open", "visit", "goto", "load", "launch"]
    static let domainPattern = try! NSRegularExpression(pattern: "^([a-z0-9-]+\\.(?:com|org|net|io|ai|co|dev|edu|gov|app))([./].*)?$", options: [.caseInsensitive])

    static func splitGluedDomain(_ token: String) -> [String] {
        let lower = token.lowercased()
        for verb in gluedVerbs where lower.hasPrefix(verb) && lower.count > verb.count + 3 {
            let rest = String(token.dropFirst(verb.count))
            if domainPattern.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
                return [String(token.prefix(verb.count)), rest]
            }
        }
        return [token]
    }

    /// Lowercase; keeps letters, digits, apostrophes, and a dot between two alphanumerics
    /// ("x.com" stays a domain, "hello." loses its period).
    public static func normalizeToken(_ token: String) -> String {
        var s = ""
        let chars = Array(token.lowercased())
        for (i, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber || ch == "'" { s.append(ch) }
            else if ch == ".", i > 0, i + 1 < chars.count, chars[i - 1].isLetter || chars[i - 1].isNumber, chars[i + 1].isLetter || chars[i + 1].isNumber { s.append(ch) }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "'."))
    }

    /// Removes the consumed prefix from a revision of the same utterance. Tolerant of the
    /// recognizer rewriting earlier words (plan section 10): if the revision does not start with
    /// the consumed words, the last three consumed words are searched as a window near where
    /// the prefix ended. Returns the unconsumed raw tail, or nil when the revision cannot be
    /// aligned and must be ignored.
    public static func stripConsumed(raw: String, consumedPrefix: String) -> String? {
        let consumed = tokens(consumedPrefix).map(normalizeToken).filter { !$0.isEmpty }
        guard !consumed.isEmpty else { return raw }
        let rawTokens = tokens(raw)
        let normalized = rawTokens.map(normalizeToken)
        // Indices of raw tokens that carry a normalized word (skip punctuation-only tokens).
        let wordIndices = normalized.indices.filter { !normalized[$0].isEmpty }
        let words = wordIndices.map { normalized[$0] }

        if words.count >= consumed.count, Array(words[0..<consumed.count]) == consumed {
            return tail(rawTokens, fromWord: consumed.count, wordIndices: wordIndices)
        }
        let anchor = Array(consumed.suffix(min(3, consumed.count)))
        let searchEnd = min(words.count, consumed.count + 3)
        guard searchEnd >= anchor.count else { return nil }
        for start in stride(from: searchEnd - anchor.count, through: 0, by: -1) {
            if Array(words[start..<start + anchor.count]) == anchor {
                return tail(rawTokens, fromWord: start + anchor.count, wordIndices: wordIndices)
            }
        }
        return nil
    }

    /// Words that carry no new command right after a consumed one: the tail of an app name
    /// ("open the notes | app"), politeness, and joiners ("| and create a new note").
    static let continuationFillers: [[String]] = [["and", "then"], ["after", "that"], ["and"], ["then"], ["next"], ["app"], ["application"],
                                                  ["please"], ["um"], ["uh"], ["now"]]

    private static func tail(_ rawTokens: [String], fromWord: Int, wordIndices: [Int]) -> String {
        var from = fromWord
        // Drop leading fillers, repeatedly ("app and create a new note" -> "create a new note").
        outer: while from < wordIndices.count {
            for filler in continuationFillers where from + filler.count <= wordIndices.count {
                let words = (from..<from + filler.count).map { normalizeToken(rawTokens[wordIndices[$0]]) }
                if words == filler { from += filler.count; continue outer }
            }
            break
        }
        guard from < wordIndices.count else { return "" }
        return rawTokens[wordIndices[from]...].joined(separator: " ")
    }

    public static func wordCount(_ raw: String) -> Int {
        tokens(raw).map(normalizeToken).filter { !$0.isEmpty }.count
    }
}
