import Foundation
import JevCore

/// Experiment for plan item 3 (from savka777/jev-use): compare our span head against a
/// `type_from`/`type_to` pair on dictations, especially ones longer than the 32-span cap.
///
/// The span head enumerates verbatim candidate spans (suffixes then inner spans, capped at 32) and
/// asks Jev to pick the one that is exactly the text. jev-use instead asks two Choice heads over
/// the sentence's words — which word is the FIRST word of the text, and which is the LAST — and
/// takes the run between them. That is linear in sentence length and never truncates.
///
/// `jev-cua lab --dictation fixtures/dictations.json`
enum DictationLab {
    struct Fixture: Decodable { let command: String; let text: String }
    struct File: Decodable { let cases: [Fixture] }

    static func run(_ args: Args) async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = cwd.appending(path: args.string("dictation")!)
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: path))
        let jev: any JevDeciding = JevCache(path: JevCache.committedPath(cwd), live: try JevClient())

        var spanRight = 0, fromToRight = 0, spanOffered = 0
        var rows: [String] = []
        for (i, c) in file.cases.enumerated() {
            let tokens = Transcript.tokens(c.command)
            let want = c.text
            FileHandle.standardError.write(Data("  [\(i + 1)/\(file.cases.count)] \(c.command)\n".utf8))

            // --- Span head (what we ship).
            let spans = Spans.extract(from: c.command)
            let offered = spans.payload.contains { $0.text == want }
            if offered { spanOffered += 1 }
            var spanPick = "—"
            do {
                let q = ["text_span": Questions.textSpanQuestion(spans.payload)]
                let ctx = DecisionContext(rawTranscript: c.command, isFinal: true, frontmostApp: "Notes",
                                          focusedField: FocusedField(role: "textarea"))
                let r = try await jev.systemOne(state: StateBuilder.state(for: ctx), questions: q, model: nil)
                spanPick = r.answers["text_span"]?.choice?.choice ?? "none"
            }
            let spanOK = spanPick == want
            if spanOK { spanRight += 1 }

            // --- from/to heads (the candidate).
            var words: [String: JSONValue] = [:]
            for (j, tok) in tokens.enumerated() {
                let before = j > 0 ? tokens[j - 1] + " " : "", after = j + 1 < tokens.count ? " " + tokens[j + 1] : ""
                words["w\(j)"] = .string("word \(j + 1) of \(tokens.count): …\(before)[\(tok)]\(after)…")
            }
            func boundary(_ end: String) -> Question {
                .choice(["question": .string("The text the user wants typed is a run of consecutive words inside `transcript`. Which word is the \(end) word of exactly that text? The text is only what should be typed — never the command words around it (type, write, enter, search for, into, in the … field, the app or field name)."),
                         "focus": .string("Pick the \(end == "FIRST" ? "first" : "last") word of the payload only.")], words)
            }
            let q2 = ["type_from": boundary("FIRST"), "type_to": boundary("LAST")]
            let ctx2 = DecisionContext(rawTranscript: c.command, isFinal: true, frontmostApp: "Notes", focusedField: FocusedField(role: "textarea"))
            let r2 = try await jev.systemOne(state: StateBuilder.state(for: ctx2), questions: q2, model: nil)
            func wordIndex(_ head: String) -> Int? {
                guard let opt = r2.answers[head]?.choice?.choice else { return nil }
                return Int(opt.dropFirst())
            }
            let from = wordIndex("type_from"), to = wordIndex("type_to")
            let fromTo: String = {
                guard let f = from, let t = to, f <= t, t < tokens.count else { return "—" }
                return tokens[f...t].joined(separator: " ")
            }()
            let ftOK = fromTo == want
            if ftOK { fromToRight += 1 }

            rows.append("| \(tokens.count) | \(offered ? "y" : "n") | \(spanOK ? "✓" : "✗") | \(ftOK ? "✓" : "✗") | \(c.command.prefix(48)) |")
            if !spanOK { rows.append("|   |   | span→ '\(spanPick.prefix(60))' | | |") }
            if !ftOK { rows.append("|   |   | | from/to→ '\(fromTo.prefix(60))' (\(from.map { $0 + 1 } ?? 0)–\(to.map { $0 + 1 } ?? 0)) | |") }
        }
        let n = file.cases.count
        print("dictation experiment: \(n) cases")
        print("  span head offered the exact text:  \(spanOffered)/\(n)")
        print("  span head picked the exact text:   \(spanRight)/\(n)")
        print("  from/to picked the exact text:     \(fromToRight)/\(n)")
        print()
        print("| words | span offered | span | from/to | command |")
        print("|---|---|---|---|---|")
        for r in rows { print(r) }
    }
}
