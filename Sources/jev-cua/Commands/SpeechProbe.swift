import Foundation
import JevCore
import JevMac

enum ProviderKind: String, CaseIterable {
    case transcriber, transcriberFast = "transcriber-fast", dictation, sfspeech
}

/// Phase 0 measurement: run one recognizer against the mic, log every event with a monotonic
/// timestamp, and print the cadence table that decides the primary provider.
enum SpeechProbe {
    static func run(_ args: Args) async throws {
        let providerName = args.string("provider") ?? "transcriber"
        guard let provider = ProviderKind(rawValue: providerName) else {
            throw UsageError("unknown provider \(providerName); use " + ProviderKind.allCases.map(\.rawValue).joined(separator: " | "))
        }
        let seconds = args.int("seconds", default: 45)
        let levelThreshold = args.float("level-threshold", default: 0.01)
        // Forced commits default to off for the analyzer providers (they finalize on their own
        // sentence boundaries) and on for SFSpeechRecognizer (endAudio is its native commit).
        let commitAfterMs = args.int("commit-after-ms", default: provider == .sfspeech ? 900 : 0)
        let quietMs = args.int("quiet-ms", default: 600)
        let quiet = args.flag("quiet")

        let mic = await Permissions.requestMicrophone()
        guard mic == .authorized else { throw UsageError("microphone permission is \(mic.rawValue)") }

        let audio = AudioInput()
        let sp: any SpeechProvider
        switch provider {
        case .transcriber: sp = SpeechTranscriberProvider(audio: audio, module: .transcriber(fast: false))
        case .transcriberFast: sp = SpeechTranscriberProvider(audio: audio, module: .transcriber(fast: true))
        case .dictation: sp = SpeechTranscriberProvider(audio: audio, module: .dictation)
        case .sfspeech: sp = try SFSpeechProvider(audio: audio)
        }

        let collector = ProbeCollector()
        let t0 = Mono.now()
        try await sp.start()
        print("[\(sp.name)] listening for \(seconds)s. Speak about ten short commands, pausing between them.")

        let levelsTask = Task {
            for await l in audio.levels { await collector.add(level: l, threshold: levelThreshold) }
        }
        let eventsTask = Task {
            for await ev in sp.events {
                switch ev {
                case .transcript(let t):
                    await collector.add(sample: SpeechProbeSample(at: t.at, text: t.text, isFinal: t.isFinal, segment: t.segment))
                    if !quiet {
                        let ms = Int((t.at - t0) * 1000)
                        print(String(format: "%7d ms  %@ seg%d  %@", ms, t.isFinal ? "FINAL " : "      ", t.segment, t.segmentText))
                    }
                case .status(let s): print(String(format: "%7d ms  [status] %@", Int((Mono.now() - t0) * 1000), s))
                case .error(let e): print("  [error] \(e)")
                }
            }
        }
        // Silence-driven segment commit, the same rule the controller will use (plan 9.5): the
        // transcript has been stable for `commitAfterMs` AND the microphone has been quiet for
        // `quietMs`. Transcript stability alone fired mid-utterance on providers whose partials
        // arrive every ~1 s, and a forced finalization mid-word returned punctuation-only finals.
        let commitTask = Task {
            guard commitAfterMs > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let now = Mono.now()
                guard let last = await collector.lastVolatileAt(), (now - last) * 1000 > Double(commitAfterMs),
                      let loud = await collector.lastLoudAt(), (now - loud) * 1000 > Double(quietMs),
                      await collector.hasUncommittedText() else { continue }
                await collector.markCommitRequested()
                if !quiet { print(String(format: "%7d ms  [commit] transcript stable %d ms, quiet %d ms", Int((now - t0) * 1000), Int((now - last) * 1000), Int((now - loud) * 1000))) }
                await sp.commitSegment()
            }
        }

        try? await Task.sleep(for: .seconds(seconds))
        commitTask.cancel()
        print(String(format: "%7d ms  [status] stopping", Int((Mono.now() - t0) * 1000)))
        await sp.stop()
        print(String(format: "%7d ms  [status] stopped", Int((Mono.now() - t0) * 1000)))
        levelsTask.cancel()
        _ = await eventsTask.result

        let samples = await collector.samples
        let levels = await collector.levels
        let stats = SpeechStats.compute(samples: samples, levels: levels, threshold: levelThreshold)

        let peak = levels.map(\.rms).max() ?? 0
        let loud = levels.filter { $0.rms > levelThreshold }.count
        print(String(format: "\naudio: %d buffers, peak rms %.3f, %d above threshold %.3f%@",
                     levels.count, peak, loud, levelThreshold,
                     levels.isEmpty ? "  (no audio reached the tap: check the microphone grant)" : ""))
        let table = SpeechStats.markdownHeader + "\n" + SpeechStats.markdownRow(provider: sp.name, stats)
        print("\n" + table)

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "runs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: "speech-probe-\(provider.rawValue)-\(ts).md")
        var md = "# speech-probe \(sp.name) \(ts)\n\nseconds=\(seconds) threshold=\(levelThreshold) commitAfterMs=\(commitAfterMs) quietMs=\(quietMs) audioBuffers=\(levels.count) peakRms=\(peak) loudBuffers=\(loud)\n\n" + table + "\n\n## events\n\n"
        for s in samples {
            md += String(format: "- %7.0f ms %@ seg%d `%@`\n", (s.at - t0) * 1000, s.isFinal ? "FINAL" : "     ", s.segment, s.text)
        }
        try md.write(to: out, atomically: true, encoding: .utf8)
        print("wrote \(out.path)")
    }
}

actor ProbeCollector {
    private(set) var samples: [SpeechProbeSample] = []
    private(set) var levels: [AudioLevel] = []
    private var commitRequestedForText: String? = nil
    private var lastLoud: TimeInterval? = nil

    func add(sample: SpeechProbeSample) {
        samples.append(sample)
        if sample.isFinal { commitRequestedForText = nil }
    }
    func add(level: AudioLevel, threshold: Float) {
        levels.append(level)
        if level.rms > threshold { lastLoud = level.at }
    }
    func lastLoudAt() -> TimeInterval? { lastLoud ?? levels.first?.at }

    func lastVolatileAt() -> TimeInterval? { samples.last(where: { !$0.isFinal })?.at }

    func hasUncommittedText() -> Bool {
        guard let last = samples.last, !last.isFinal, !last.text.isEmpty else { return false }
        return commitRequestedForText != last.text
    }
    func markCommitRequested() { commitRequestedForText = samples.last?.text }
}
