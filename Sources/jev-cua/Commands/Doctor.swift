import Foundation
import JevCore
import JevMac

enum Doctor {
    static func run(_ args: Args) async throws {
        let report = await DoctorReport.build(prompt: args.flag("prompt"))
        print(report.text)
        if args.flag("live") {
            print("")
            try await liveCheck()
        }
    }

    static func liveCheck() async throws {
        let client = try JevClient()
        let state: JSONValue = ["transcript": "open the notes app and create a new note"]
        let questions: [String: Question] = [
            "is_command": .noul("Is `transcript` an instruction addressed to this computer (open, search, click, type, scroll)?"),
        ]
        let resp = try await client.systemOne(state: state, questions: questions, model: nil)
        let p = resp.answers["is_command"]?.noul ?? -1
        print(String(format: "live via %@: model=%@ is_command=%.3f latency=%.0f ms tokens=%d cost=$%.6f request=%@",
                     client.endpoint.kind.rawValue, resp.model, p, resp.latencyMs, resp.usage.inputTokens, resp.usage.costUSD, resp.requestId ?? "-"))
    }
}

struct DoctorReport {
    var rows: [(String, String)] = []
    var text: String {
        let w = rows.map { $0.0.count }.max() ?? 10
        return rows.map { $0.0.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + $0.1 }.joined(separator: "\n")
    }

    static func build(prompt: Bool) async -> DoctorReport {
        var r = DoctorReport()
        let dotenv = Env.dotenvPath
        r.rows.append(("dotenv", dotenv.map { $0.path } ?? "not found (walked up from cwd)"))
        do {
            let endpoint = try JevEndpoint.current()
            r.rows.append(("jev endpoint", endpoint.summary))
            if endpoint.kind == .gateway {
                r.rows.append((endpoint.keyName, Env.secret(endpoint.keyName) != nil ? "present" : "MISSING"))
                if !endpoint.pinned {
                    r.rows.append(("model pin", "\(endpoint.model) follows TypeSafe's latest release; thresholds were tuned on \(Config.model)"))
                }
            }
        } catch {
            r.rows.append(("jev endpoint", "INVALID: \(error)"))
        }
        r.rows.append(("TYPESAFE_API_KEY", Env.apiKeyPresent ? "present" : "MISSING"))
        r.rows.append(("model pin", Config.model + " (direct endpoint)"))
        r.rows.append(("bundle", Bundle.main.bundleIdentifier ?? "none (unbundled binary; permissions attach to the launching terminal)"))
        r.rows.append(("executable", Bundle.main.executableURL?.path ?? "?"))

        let mic = prompt ? await Permissions.requestMicrophone() : Permissions.microphone()
        r.rows.append(("microphone", mic.rawValue))
        let sp = prompt ? await Permissions.requestSpeech() : Permissions.speech()
        r.rows.append(("speech recognition", sp.rawValue))
        let ax = Permissions.accessibility(prompt: prompt)
        r.rows.append(("accessibility", ax.rawValue))

        let assets = await SpeechTranscriberProvider.assetStatus()
        r.rows.append(("SpeechTranscriber en-US", "supported=\(assets.supported) installed=\(assets.installed)"))
        let dict = await SpeechTranscriberProvider.dictationAssetStatus()
        r.rows.append(("DictationTranscriber en-US", "supported=\(dict.supported) installed=\(dict.installed)"))
        let sf = SFSpeechProvider.status()
        r.rows.append(("SFSpeechRecognizer en-US", "available=\(sf.available) onDevice=\(sf.onDevice)"))

        let runs = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "runs")
        r.rows.append(("runs dir", runs.path))
        return r
    }
}
