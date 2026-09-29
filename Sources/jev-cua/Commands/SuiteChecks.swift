import Foundation
import JevCore
import JevMac

/// Evidence checks shared by the goals and sessions suites. Read from a fresh observation after
/// the run, independent of the loop's own verdict, so a false completion counts as one.
struct SuiteCheck: Decodable {
    var page_host: String?
    var frontmost_app: String?
    var element_texts_contain: [String]?
    var element_text_absent: String?
    var focused_value_contains: [String]?
    /// Substrings the focused value must not contain (a replaced title must lose the old one).
    var focused_value_lacks: [String]?
    /// The focused value, split into lines, must contain these substrings on strictly
    /// increasing lines: catches a note whose body was appended to the title line.
    var value_lines_ordered: [String]?
    var forbid_actions: [String]?
    var last_action_verified: String?
    /// The executor's own evidence for the last action must contain this: "window count" for a
    /// window's close button, which a page's text once verified.
    var last_evidence_contains: String?
    /// The case's app must end with this many more windows than it had after setup: 0 after
    /// "close this tab". (No tab count: a busy window's strip stops counting at the tabs it shows.)
    var window_count_change: Int?
    /// Exact field values by label, read from the page's text fields.
    var field_values: [String: String]?

    /// `actions` are the run's action summaries in order; `last` is the final one and whether it
    /// verified; `lastEvidence` what the executor observed for it; `before` the counts taken
    /// after setup, before the first phrase.
    func evaluate(obs: Observation, actions: [String], last: (action: String, verified: Bool)?,
                  lastEvidence: String? = nil, before: SuiteBaseline? = nil) -> (ok: Bool, why: String) {
        var problems: [String] = []
        if let h = page_host, (obs.pageHost ?? "") != h { problems.append("host \(obs.pageHost ?? "none") ≠ \(h)") }
        if let a = frontmost_app, obs.app.name != a { problems.append("front \(obs.app.name) ≠ \(a)") }
        var texts = obs.elements.map(\.text) + [obs.focusedField?.valuePreview ?? ""]
        if obs.pageHost != nil || obs.app.bundleId == "com.google.Chrome" { texts += Browser.pageTexts(pid: obs.app.pid) }
        for t in element_texts_contain ?? [] where !texts.contains(where: { $0.localizedCaseInsensitiveContains(t) }) { problems.append("no element with '\(t)'") }
        if let absent = element_text_absent, texts.contains(where: { $0.contains(absent) }) { problems.append("'\(absent)' present") }
        let value = Browser.focusedValue(pid: obs.app.pid) ?? obs.focusedField?.valuePreview ?? ""
        for t in focused_value_contains ?? [] where !value.localizedCaseInsensitiveContains(t) { problems.append("focused value lacks '\(t)'") }
        for t in focused_value_lacks ?? [] where value.localizedCaseInsensitiveContains(t) { problems.append("focused value still has '\(t)'") }
        if let want = value_lines_ordered {
            let lines = value.components(separatedBy: .newlines)
            var after = -1
            for t in want {
                if let line = lines.indices.first(where: { $0 > after && lines[$0].localizedCaseInsensitiveContains(t) }) { after = line }
                else { problems.append("'\(t)' not on a line below the previous (value: '\(value.replacingOccurrences(of: "\n", with: "⏎").prefix(60))')"); break }
            }
        }
        for kind in forbid_actions ?? [] where actions.contains(where: { $0.hasPrefix(kind) }) { problems.append("forbidden \(kind) happened") }
        if let k = last_action_verified, !(last.map { $0.action.hasPrefix(k) && $0.verified } ?? false) {
            problems.append("last action not a verified \(k)" + (last.map { " (was \($0.action)\($0.verified ? "" : ", unverified"))" } ?? " (no action)"))
        }
        if let want = last_evidence_contains, !(lastEvidence ?? "").contains(want) {
            problems.append("last evidence '\(lastEvidence ?? "none")' lacks '\(want)'")
        }
        if let want = window_count_change {
            if let b = before {
                let now = SuiteBaseline.take(pid: b.pid)
                if now.windows - b.windows != want { problems.append("windows \(b.windows) -> \(now.windows), want a change of \(want)") }
            } else { problems.append("no window count from before the phrases") }
        }
        if let fv = field_values {
            let values = Browser.fieldValues(pid: obs.app.pid)
            for (label, want) in fv {
                let got = values.first { $0.key.localizedCaseInsensitiveContains(label) }?.value ?? ""
                if got != want { problems.append("field '\(label)' = '\(got)' ≠ '\(want)'") }
            }
        }
        return (problems.isEmpty, problems.isEmpty ? "evidence ok" : problems.joined(separator: "; "))
    }
}

/// The case's app's window count, taken after setup and again for the evidence check.
struct SuiteBaseline {
    var pid: pid_t
    var windows: Int
    static func take(pid: pid_t) -> SuiteBaseline { SuiteBaseline(pid: pid, windows: AX.windowCount(pid: pid)) }
}
