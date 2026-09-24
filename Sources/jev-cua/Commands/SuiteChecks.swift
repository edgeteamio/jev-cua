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
    /// Exact field values by label, read from the page's text fields.
    var field_values: [String: String]?

    /// `actions` are the run's action summaries in order; `last` is the final one and whether it verified.
    func evaluate(obs: Observation, actions: [String], last: (action: String, verified: Bool)?) -> (ok: Bool, why: String) {
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
