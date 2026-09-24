import Foundation

// The Phase 1 decision lab (plan section 12, Phase 1). Feeds every word-by-word prefix of every
// fixture command through the questions and the policy, exactly as the session will, and
// reports where each command becomes fireable. Answers are cached so re-runs are free.

// MARK: - Fixtures

public struct FixtureCommand: Codable, Sendable {
    public var text: String
    public var intent: String
    public var app: String?
    public var site: String?
    /// Expected verbatim payload (query or typed text).
    public var span: String?
    /// Expected spoken domain candidate.
    public var url: String?
    /// Prefix length (in words) at which the verb and its required object are both present.
    public var minWords: Int?
    /// Intents that count as correct besides `intent` (for commands that are ambiguous without
    /// screen elements, e.g. "press take photo" as click_element or take_photo).
    public var altIntents: [String]?
    /// Spans that count as correct besides `span` (articles or site words Jev may keep or drop).
    public var altSpans: [String]?
    /// For compound utterances: the intents expected to fire in order as clauses are consumed.
    /// Defaults to [intent].
    public var expectedActs: [String]?
    public var frontmostApp: String?
    public var frontmostBundleId: String?
    public var focusedField: FocusedField?
    public var pending: String?
    public var note: String?
}

public struct FixtureNonCommand: Codable, Sendable {
    public var text: String
    public var note: String?
}

public struct Fixtures: Codable, Sendable {
    public var commands: [FixtureCommand]
    public var nonCommands: [FixtureNonCommand]

    public static func load(_ url: URL) throws -> Fixtures {
        try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

// MARK: - Results

public struct PrefixRow: Codable, Sendable {
    public var words: Int
    public var prefix: String
    public var isFinal: Bool
    public var intent: String
    public var intentConfidence: Double
    public var complete: Double
    public var isCommand: Double
    public var app: String?
    public var site: String?
    public var span: String?
    public var spanConfidence: Double?
    public var url: String?
    public var decision: String
    public var summary: String
    public var lastGate: String
    public var latencyMs: Double
    public var inputTokens: Int
    public var cached: Bool
}

public struct CommandResult: Codable, Sendable {
    public var fixture: FixtureCommand
    public var rows: [PrefixRow]
    public var finalIntentCorrect: Bool
    public var finalAppCorrect: Bool?
    public var finalSiteCorrect: Bool?
    public var finalSpanCorrect: Bool?
    public var finalDecision: String
    /// First prefix word count at which the policy acted, if any.
    public var firstActAt: Int?
    /// Prefixes shorter than minWords on which the policy acted (must be zero).
    public var prematureActs: [Int]
    /// Intents that actually fired, in order, as clauses were consumed.
    public var acts: [String]
    public var actsCorrect: Bool
}

public struct NonCommandResult: Codable, Sendable {
    public var fixture: FixtureNonCommand
    public var rows: [PrefixRow]
    /// Any prefix on which the policy acted or asked for confirmation (must be none).
    public var falseFires: [Int]
    public var finalIsCommand: Double
    public var finalIntent: String
}

public struct LabSummary: Codable, Sendable {
    public var name: String
    public var commands: Int
    public var nonCommands: Int
    public var finalIntentAccuracy: Double
    public var finalIntentCorrect: Int
    /// Commands whose fired intents matched expectedActs in order (compound utterances included).
    public var actsCorrect: Int
    public var appAccuracy: Double?
    public var siteAccuracy: Double?
    public var spanAccuracy: Double?
    public var prematureActs: Int
    public var falseFires: Int
    /// Allowlisted commands that acted exactly at the first prefix where the object was present
    /// (minWords). For "open chrome" that is the final word; for "open the notes app" it is word 3.
    public var firedAtFirstFireable: Int
    public var earlyFireCandidates: Int   // allowlisted commands total
    public var liveCalls: Int
    public var cachedCalls: Int
    public var latencyP50Ms: Double?
    public var latencyP95Ms: Double?
    public var inputTokensTotal: Int
    public var costUSD: Double
}

public struct LabReport: Codable, Sendable {
    public var summary: LabSummary
    public var commands: [CommandResult]
    public var nonCommands: [NonCommandResult]
}

// MARK: - Runner

public struct LabRunner: Sendable {
    public var decider: any JevDeciding
    public var installedApps: [String]
    public var progress: (@Sendable (String) -> Void)?

    public init(decider: any JevDeciding, installedApps: [String] = [], progress: (@Sendable (String) -> Void)? = nil) {
        self.decider = decider; self.installedApps = installedApps; self.progress = progress
    }

    /// One prefix, exactly as the session would evaluate it.
    func evaluate(prefixTokens: [String], isFinal: Bool, cmd: FixtureCommand?, previousIntent: String?, consumedPrefix: String = "") async throws -> (PrefixRow, PolicyResult)? {
        let full = prefixTokens.joined(separator: " ")
        // Simulate the session's consumed-prefix rule: after an act, later words in the same
        // breath are a new command only once at least two new words exist.
        guard let raw = Transcript.stripConsumed(raw: full, consumedPrefix: consumedPrefix) else { return nil }
        if !consumedPrefix.isEmpty, Transcript.wordCount(raw) < 2 { return nil }
        let spans = Spans.extract(from: raw)
        let pending = cmd?.pending.map { Candidate(id: "pending", snapshotId: "lab", action: .pressEnter, expectedPostcondition: $0) }
        var ctx = DecisionContext(rawTranscript: raw, isFinal: isFinal, frontmostApp: cmd?.frontmostApp ?? "Finder",
                                  frontmostBundleId: cmd?.frontmostBundleId, focusedField: cmd?.focusedField,
                                  pendingConfirmation: cmd?.pending, installedApps: installedApps)
        ctx.afterConsumed = !consumedPrefix.isEmpty
        let questions = Questions.build(spans: spans, installedApps: Questions.relevantInstalledApps(installedApps, transcript: raw), rawTranscript: raw)
        let state = StateBuilder.state(for: ctx)
        let resp: JevResponse
        do {
            resp = try await decider.systemOne(state: state, questions: questions, model: nil)
        } catch let JevError.malformed(m) {
            progress?("    MALFORMED on '\(raw)': \(m.description)")
            let row = PrefixRow(words: prefixTokens.count, prefix: raw, isFinal: isFinal, intent: "malformed", intentConfidence: 0, complete: 0, isCommand: 0,
                                app: nil, site: nil, span: nil, spanConfidence: nil, url: nil, decision: "malformed", summary: m.description,
                                lastGate: "validation", latencyMs: 0, inputTokens: 0, cached: false)
            return (row, PolicyResult(outcome: .wait(reason: "malformed answer", retryInMs: nil), candidate: nil, reasons: [], summary: m.description, intent: "malformed", intentConfidence: 0, commandSpan: nil))
        }
        let intent = resp.answers["intent"]?.choice?.choice ?? "none"
        let policy = Policy.evaluate(PolicyInput(answers: resp.answers, spans: spans, context: ctx, silentMs: 0,
                                                 intentStable: previousIntent == intent, pending: pending, snapshotId: "lab"))
        let row = PrefixRow(
            words: prefixTokens.count, prefix: raw, isFinal: isFinal,
            intent: intent, intentConfidence: resp.answers["intent"]?.choice?.confidence ?? 0,
            complete: resp.answers["complete"]?.noul ?? 0, isCommand: resp.answers["is_command"]?.noul ?? 0,
            app: resp.answers["app"]?.choice?.choice, site: resp.answers["site"]?.choice?.choice,
            span: resp.answers["text_span"]?.choice?.choice, spanConfidence: resp.answers["text_span"]?.choice?.confidence,
            url: resp.answers["url_span"]?.choice?.choice,
            decision: policy.outcome.name, summary: policy.summary, lastGate: policy.reasons.last?.name ?? "-",
            latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens, cached: resp.latencyMs == 0)
        return (row, policy)
    }

    public func run(_ fixtures: Fixtures, name: String) async throws -> LabReport {
        var commands: [CommandResult] = []
        for (i, cmd) in fixtures.commands.enumerated() {
            progress?("[\(i + 1)/\(fixtures.commands.count)] \(cmd.text)")
            let tokens = Transcript.tokens(cmd.text)
            var rows: [PrefixRow] = []
            var previous: String? = nil
            var firstAct: Int? = nil
            var premature: [Int] = []
            var finalPolicy: PolicyResult? = nil
            let minWords = cmd.minWords ?? tokens.count
            var consumed = ""
            var acts: [String] = []
            var firstActPayload: String?
            var firstClauseFinal: PrefixRow? = nil
            var cmdState = cmd
            for n in 1...tokens.count {
                let isFinal = n == tokens.count
                let full = tokens[0..<n].joined(separator: " ")
                let raw = Transcript.stripConsumed(raw: full, consumedPrefix: consumed) ?? ""
                guard let (row, policy) = try await evaluate(prefixTokens: Array(tokens[0..<n]), isFinal: isFinal, cmd: cmdState,
                                                              previousIntent: previous, consumedPrefix: consumed) else { continue }
                rows.append(row)
                if row.decision == "act" || row.decision == "confirm" {
                    if firstAct == nil { firstAct = n; firstClauseFinal = row; firstActPayload = policy.candidate?.payload }
                    if n < minWords, acts.isEmpty { premature.append(n) }
                    acts.append(policy.intent)
                    consumed = (consumed + " " + (policy.commandSpan ?? raw)).trimmingCharacters(in: .whitespaces)
                    previous = nil
                    cmdState.pending = nil   // a confirmed or cancelled action is no longer pending
                    continue
                }
                previous = row.intent
                if isFinal { finalPolicy = policy }
            }
            // The row that decided the first clause: the first act, else the final row.
            let final = firstClauseFinal ?? rows.last!
            let expectedSpan = cmd.span ?? cmd.url
            let gotSpan = finalPolicy?.candidate?.payload ?? (firstClauseFinal != nil ? nil : nil)
            let expectedActs = cmd.expectedActs ?? [cmd.intent]
            let accepted = Set([cmd.intent] + (cmd.altIntents ?? []))
            commands.append(CommandResult(
                fixture: cmd, rows: rows,
                finalIntentCorrect: accepted.contains(final.intent),
                finalAppCorrect: cmd.app.map { $0 == final.app },
                finalSiteCorrect: cmd.site.map { $0 == final.site },
                finalSpanCorrect: expectedSpan.map { e in
                    // Score the payload the candidate carries (what would be searched or typed),
                    // which code may have cleaned; fall back to Jev's raw pick.
                    let got = (firstActPayload ?? rows.first { $0.decision == "act" }?.span ?? rows.first { $0.decision == "act" }?.url ?? gotSpan ?? "").lowercased()
                    return ([e] + (cmd.altSpans ?? [])).contains { $0.lowercased() == got }
                },
                finalDecision: final.decision, firstActAt: firstAct, prematureActs: premature,
                acts: acts,
                actsCorrect: acts == expectedActs || (cmd.expectedActs == nil && acts.count == 1 && accepted.contains(acts[0]))
                    || (acts.isEmpty && cmd.expectedActs == nil && accepted.contains(final.intent) && final.decision != "act")))
        }

        var nonCommands: [NonCommandResult] = []
        for (i, nc) in fixtures.nonCommands.enumerated() {
            progress?("[non-command \(i + 1)/\(fixtures.nonCommands.count)] \(nc.text)")
            let tokens = Transcript.tokens(nc.text)
            var rows: [PrefixRow] = []
            var previous: String? = nil
            var fires: [Int] = []
            for n in 1...tokens.count {
                guard let (row, _) = try await evaluate(prefixTokens: Array(tokens[0..<n]), isFinal: n == tokens.count, cmd: nil, previousIntent: previous) else { continue }
                rows.append(row)
                if row.decision == "act" || row.decision == "confirm" { fires.append(n) }
                previous = row.intent
            }
            nonCommands.append(NonCommandResult(fixture: nc, rows: rows, falseFires: fires,
                                                finalIsCommand: rows.last!.isCommand, finalIntent: rows.last!.intent))
        }

        let allRows = commands.flatMap(\.rows) + nonCommands.flatMap(\.rows)
        let live = allRows.filter { !$0.cached }
        let lat = live.map(\.latencyMs).sorted()
        func pct(_ p: Double) -> Double? { lat.isEmpty ? nil : lat[min(lat.count - 1, Int(Double(lat.count - 1) * p))] }
        func acc(_ xs: [Bool?]) -> Double? { let v = xs.compactMap { $0 }; return v.isEmpty ? nil : Double(v.filter { $0 }.count) / Double(v.count) }
        let allowlisted = commands.filter { Config.earlyExecutionKinds.contains($0.fixture.intent) && Transcript.tokens($0.fixture.text).count > 1 }
        let tokensTotal = allRows.map(\.inputTokens).reduce(0, +)
        let summary = LabSummary(
            name: name, commands: commands.count, nonCommands: nonCommands.count,
            finalIntentAccuracy: commands.isEmpty ? 0 : Double(commands.filter(\.finalIntentCorrect).count) / Double(commands.count),
            finalIntentCorrect: commands.filter(\.finalIntentCorrect).count,
            actsCorrect: commands.filter(\.actsCorrect).count,
            appAccuracy: acc(commands.map(\.finalAppCorrect)), siteAccuracy: acc(commands.map(\.finalSiteCorrect)),
            spanAccuracy: acc(commands.map(\.finalSpanCorrect)),
            prematureActs: commands.map { $0.prematureActs.count }.reduce(0, +),
            falseFires: nonCommands.map { $0.falseFires.count }.reduce(0, +),
            firedAtFirstFireable: allowlisted.filter { r in r.firstActAt == (r.fixture.minWords ?? Transcript.tokens(r.fixture.text).count) }.count,
            earlyFireCandidates: allowlisted.count,
            liveCalls: live.count, cachedCalls: allRows.count - live.count,
            latencyP50Ms: pct(0.5), latencyP95Ms: pct(0.95),
            inputTokensTotal: tokensTotal, costUSD: Double(tokensTotal) / 1_000_000 * Config.pricePerMillionInputTokensUSD)
        return LabReport(summary: summary, commands: commands, nonCommands: nonCommands)
    }
}

// MARK: - Report rendering

public enum LabRender {
    public static func summaryText(_ s: LabSummary) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "n/a" }
        return """
        \(s.name): \(s.commands) commands, \(s.nonCommands) non-commands
          final intent accuracy   \(f(s.finalIntentAccuracy)) (\(s.finalIntentCorrect)/\(s.commands)); fired sequence correct \(s.actsCorrect)/\(s.commands)
          app / site / span       \(f(s.appAccuracy)) / \(f(s.siteAccuracy)) / \(f(s.spanAccuracy))
          premature acts          \(s.prematureActs)   (acts on a prefix shorter than minWords; must be 0)
          false fires             \(s.falseFires)   (acts on non-commands; must be 0)
          fired at first fireable \(s.firedAtFirstFireable)/\(s.earlyFireCandidates) allowlisted commands acted at the first prefix with verb + object
          calls                   \(s.liveCalls) live, \(s.cachedCalls) cached; latency p50 \(ms(s.latencyP50Ms)) p95 \(ms(s.latencyP95Ms))
          tokens / cost           \(s.inputTokensTotal) / $\(String(format: "%.4f", s.costUSD))
        """
    }

    public static func markdown(_ r: LabReport) -> String {
        var md = "# lab \(r.summary.name)\n\n```\n" + summaryText(r.summary) + "\n```\n\n"
        md += "## commands\n\n"
        for c in r.commands {
            let flags = [c.finalIntentCorrect ? "" : "INTENT WRONG", c.prematureActs.isEmpty ? "" : "PREMATURE \(c.prematureActs)",
                         c.finalAppCorrect == false ? "app wrong" : "", c.finalSiteCorrect == false ? "site wrong" : "",
                         c.finalSpanCorrect == false ? "span wrong" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
            md += "### \(c.fixture.text)\nacts \(c.acts) \(c.actsCorrect ? "" : "**SEQUENCE WRONG** ")expected \(c.fixture.intent)\(c.fixture.app.map { " app=\($0)" } ?? "")\(c.fixture.site.map { " site=\($0)" } ?? "")\(c.fixture.span.map { " span='\($0)'" } ?? "")\(c.fixture.url.map { " url='\($0)'" } ?? ""); first act at word \(c.firstActAt.map(String.init) ?? "-") of \(c.rows.count)\(flags.isEmpty ? "" : "  **\(flags)**")\n\n"
            md += "| words | prefix | intent | conf | complete | is_cmd | app | site | span | decision | gate |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
            for row in c.rows {
                md += "| \(row.words)\(row.isFinal ? "F" : "") | \(row.prefix) | \(row.intent) | \(String(format: "%.2f", row.intentConfidence)) | \(String(format: "%.2f", row.complete)) | \(String(format: "%.2f", row.isCommand)) | \(row.app ?? "-") | \(row.site ?? "-") | \(row.span.map { "\($0) (\(String(format: "%.2f", row.spanConfidence ?? 0)))" } ?? row.url ?? "-") | **\(row.decision)** | \(row.lastGate) |\n"
            }
            md += "\n"
        }
        md += "## non-commands\n\n| text | final intent | is_cmd | false fires |\n|---|---|---|---|\n"
        for n in r.nonCommands {
            md += "| \(n.fixture.text) | \(n.finalIntent) | \(String(format: "%.2f", n.finalIsCommand)) | \(n.falseFires.isEmpty ? "none" : "**\(n.falseFires)**") |\n"
        }
        return md
    }
}

// MARK: - Target lab (Phase 4)

/// A captured screen (`jev-cua ax --walk --json`) plus commands with the element each should
/// target. `expect` is an element id, `none` (no element should be chosen), or `ambiguous`
/// (badges expected).
public struct TargetFixture: Codable, Sendable {
    public struct Command: Codable, Sendable {
        public var text: String
        public var expect: String
        public var intent: String?      // default click_element; type_text uses type_target
        public var focusedField: FocusedField?
        /// Intents that satisfy the command without a target ("click new note" as `new_note`).
        public var altIntents: [String]?
    }
    public var app: String
    public var bundleId: String?
    public var elements: [Element]
    public var offscreen: [Element]?
    public var commands: [Command]

    public init(app: String, bundleId: String?, elements: [Element], offscreen: [Element]?, commands: [Command]) {
        self.app = app; self.bundleId = bundleId; self.elements = elements; self.offscreen = offscreen; self.commands = commands
    }

    public static func load(_ url: URL) throws -> TargetFixture {
        try JSONDecoder().decode(TargetFixture.self, from: Data(contentsOf: url))
    }
}

public struct TargetRow: Codable, Sendable {
    public var text: String
    public var expect: String
    public var covered: Bool         // the expected element is in the list at all
    public var intent: String
    public var picked: String?       // element id chosen (or "ambiguous"/"none")
    public var confidence: Double?
    public var topProbability: Double?
    public var decision: String
    public var correct: Bool
    public var latencyMs: Double
    public var inputTokens: Int
}

public struct TargetReport: Codable, Sendable {
    public var app: String
    public var rows: [TargetRow]
    public var elementCount: Int
    public var correct: Int { rows.filter(\.correct).count }
    public var covered: Int { rows.filter(\.covered).count }
    public var tokensTotal: Int { rows.reduce(0) { $0 + $1.inputTokens } }
}

extension LabRunner {
    public func runTargets(_ f: TargetFixture) async throws -> TargetReport {
        var rows: [TargetRow] = []
        for (i, cmd) in f.commands.enumerated() {
            progress?("[\(i + 1)/\(f.commands.count)] \(f.app): \(cmd.text)")
            let raw = Transcript.normalize(cmd.text)
            let spans = Spans.extract(from: raw)
            var ctx = DecisionContext(rawTranscript: raw, isFinal: true, frontmostApp: f.app, frontmostBundleId: f.bundleId,
                                      focusedField: cmd.focusedField, elements: f.elements, installedApps: installedApps)
            ctx.offscreen = f.offscreen ?? []
            let questions = Questions.build(spans: spans, installedApps: [], rawTranscript: raw, elements: f.elements, offscreen: f.offscreen ?? [])
            let resp = try await decider.systemOne(state: StateBuilder.state(for: ctx), questions: questions, model: nil)
            let policy = Policy.evaluate(PolicyInput(answers: resp.answers, spans: spans, context: ctx, silentMs: 1000, intentStable: true, snapshotId: "lab"))
            let intent = resp.answers["intent"]?.choice?.choice ?? "none"
            let head = (cmd.intent ?? "click_element") == "type_text" ? "type_target" : "click_target"
            let ans = resp.answers[head]?.choice
            let picked: String? = {
                switch policy.outcome {
                case .act: return policy.candidate?.targetElementId ?? "none"
                case .disambiguate: return "ambiguous"
                default: return ans?.choice == Questions.targetNone ? "none" : ans?.choice
                }
            }()
            let covered = cmd.expect == "none" || cmd.expect == "ambiguous" || (f.elements + (f.offscreen ?? [])).contains { $0.id == cmd.expect }
            let denied = policy.outcome.name == "ignore" && policy.summary.hasPrefix("denied")
            let selected = ans?.choice
            let correct: Bool = {
                switch cmd.expect {
                case "none": return policy.outcome.name != "act" && policy.outcome.name != "disambiguate"
                case "ambiguous": return policy.outcome.name == "disambiguate"
                default:
                    if policy.outcome.name == "act", policy.candidate?.targetElementId == cmd.expect { return true }
                    // The right element was selected and policy then refused it (deny-listed app): selection is right.
                    if denied, selected == cmd.expect { return true }
                    // An intent that does the same thing without a target.
                    if policy.outcome.name == "act", let alts = cmd.altIntents, alts.contains(intent) { return true }
                    return false
                }
            }()
            rows.append(TargetRow(text: cmd.text, expect: cmd.expect, covered: covered, intent: intent, picked: picked, confidence: ans?.confidence,
                                  topProbability: ans?.ranked(excluding: [Questions.targetNone, Questions.targetFocused]).first?.p,
                                  decision: policy.outcome.name + (policy.outcome.name == "act" ? "" : " (\(policy.summary))"),
                                  correct: correct, latencyMs: resp.latencyMs, inputTokens: resp.usage.inputTokens))
        }
        return TargetReport(app: f.app, rows: rows, elementCount: f.elements.count)
    }
}

extension LabRender {
    public static func targetsText(_ r: TargetReport) -> String {
        var out = "targets: \(r.app) (\(r.elementCount) elements): \(r.correct)/\(r.rows.count) correct, coverage \(r.covered)/\(r.rows.count), tokens \(r.tokensTotal)\n"
        for row in r.rows where !row.correct {
            out += String(format: "  ✗ \"%@\" expected %@, got %@ [%@]%@\n", row.text, row.expect, row.picked ?? "-", row.decision,
                          row.covered ? "" : "  (NOT COVERED)")
        }
        return out
    }

    public static func targetsMarkdown(_ r: TargetReport) -> String {
        var md = "# Target lab: \(r.app)\n\n\(r.elementCount) elements; \(r.correct)/\(r.rows.count) correct; coverage \(r.covered)/\(r.rows.count); tokens \(r.tokensTotal)\n\n"
        md += "| command | expect | picked | conf | top p | decision | ok |\n|---|---|---|---|---|---|---|\n"
        for row in r.rows {
            md += "| \(row.text) | \(row.expect) | \(row.picked ?? "-") | \(row.confidence.map { String(format: "%.2f", $0) } ?? "-") | \(row.topProbability.map { String(format: "%.2f", $0) } ?? "-") | \(row.decision) | \(row.correct ? "✓" : "✗") |\n"
        }
        return md
    }
}
