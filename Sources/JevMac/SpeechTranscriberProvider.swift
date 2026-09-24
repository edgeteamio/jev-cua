import AVFoundation
import CoreMedia
import Foundation
import JevCore
import Speech
import os

/// macOS 26 SpeechAnalyzer with one of its transcription modules, on-device, volatile results.
///
/// Two modules are offered because Phase 0 measures them: `SpeechTranscriber` (general
/// transcription, optionally with `fastResults`) and `DictationTranscriber` with the
/// `shortForm` content hint and `frequentFinalization`, which is the profile for short spoken
/// commands. The first probe run showed `SpeechTranscriber` at default priority emitting every
/// partial of a phrase in one burst after the phrase ended, so the analyzer now also runs at
/// user-initiated priority.
public final class SpeechTranscriberProvider: SpeechProvider, @unchecked Sendable {
    public enum Module: Sendable, Equatable {
        case transcriber(fast: Bool)
        case dictation
    }

    public let name: String
    public let events: AsyncStream<SpeechEvent>

    private let eventCont: AsyncStream<SpeechEvent>.Continuation
    private let audio: AudioInput
    private let locale: Locale
    private let module: Module
    private let converter = BufferConverter()

    private struct State {
        var analyzer: SpeechAnalyzer?
        var inputCont: AsyncStream<AnalyzerInput>.Continuation?
        var analyzerFormat: AVAudioFormat?
        var resultsTask: Task<Void, Never>?
        var acc = TranscriptAccumulator()
        /// Frames sent to the analyzer so far, in the analyzer's sample rate. The analyzer
        /// derives every buffer's time from frame counts, so this is its clock.
        var sentFrames: Int64 = 0
        var lastBufferEnd: CMTime = .zero
        /// End of the last result range the analyzer produced: the latest time it has
        /// demonstrably decoded. Forced finalization must not go past this (see commitSegment).
        var lastResultEnd: CMTime = .zero
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(audio: AudioInput, locale: Locale = Locale(identifier: "en-US"), module: Module = .transcriber(fast: false)) {
        self.audio = audio
        self.locale = locale
        self.module = module
        switch module {
        case .transcriber(let fast): name = fast ? "SpeechTranscriber(fast)" : "SpeechTranscriber"
        case .dictation: name = "DictationTranscriber(shortForm)"
        }
        (events, eventCont) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public convenience init(audio: AudioInput, locale: Locale = Locale(identifier: "en-US"), fastResults: Bool) {
        self.init(audio: audio, locale: locale, module: .transcriber(fast: fastResults))
    }

    public func start() async throws {
        let speechModule: any SpeechModule
        let resultsTask: (SpeechTranscriberProvider) -> Task<Void, Never>

        switch module {
        case .transcriber(let fast):
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if fast { reporting.insert(.fastResults) }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [.audioTimeRange])
            try await Self.ensureModel(for: t, locale: locale, installed: SpeechTranscriber.installedLocales,
                                       supported: SpeechTranscriber.supportedLocales) { [eventCont] in eventCont.yield(.status($0)) }
            speechModule = t
            resultsTask = { provider in
                Task { [weak provider] in
                    do { for try await r in t.results { provider?.handle(text: String(r.text.characters), isFinal: r.isFinal, rangeEnd: r.range.end) } }
                    catch { provider?.eventCont.yield(.error("transcriber results: \(error)")) }
                }
            }
        case .dictation:
            let d = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                                         reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
            try await Self.ensureModel(for: d, locale: locale, installed: DictationTranscriber.installedLocales,
                                       supported: DictationTranscriber.supportedLocales) { [eventCont] in eventCont.yield(.status($0)) }
            speechModule = d
            resultsTask = { provider in
                Task { [weak provider] in
                    do { for try await r in d.results { provider?.handle(text: String(r.text.characters), isFinal: r.isFinal, rangeEnd: r.range.end) } }
                    catch { provider?.eventCont.yield(.error("dictation results: \(error)")) }
                }
            }
        }

        eventCont.yield(.status("model ready"))
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [speechModule], options: options)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechModule]) else {
            throw SpeechProviderError.unavailable("no compatible audio format for \(name)")
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        state.withLockUnchecked {
            $0.analyzer = analyzer; $0.inputCont = cont; $0.analyzerFormat = format
        }

        try await analyzer.start(inputSequence: stream)
        eventCont.yield(.status("analyzer started"))
        let task = resultsTask(self)
        state.withLockUnchecked { $0.resultsTask = task }

        try audio.start { [weak self] buffer, when in self?.push(buffer, when) }
        eventCont.yield(.status("\(name) listening (\(Int(format.sampleRate)) Hz, priority userInitiated)"))
    }

    private func push(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let (format, cont) = state.withLockUnchecked { ($0.analyzerFormat, $0.inputCont) }
        guard let format, let cont else { return }
        guard let converted = try? converter.convert(buffer, to: format), converted.frameLength > 0 else { return }
        // No explicit bufferStartTime: stamping converted buffers with the mic clock produced
        // sub-millisecond overlaps after resampling and the analyzer rejected the stream
        // (SFSpeechErrorDomain 2). Sequential input is what Apple's sample does.
        state.withLockUnchecked {
            $0.sentFrames += Int64(converted.frameLength)
            $0.lastBufferEnd = CMTime(value: $0.sentFrames, timescale: CMTimeScale(format.sampleRate))
        }
        cont.yield(AnalyzerInput(buffer: converted))
    }

    private func handle(text: String, isFinal: Bool, rangeEnd: CMTime) {
        let now = Mono.now()
        let ev = state.withLockUnchecked {
            if rangeEnd.isValid, CMTimeCompare(rangeEnd, $0.lastResultEnd) > 0 { $0.lastResultEnd = rangeEnd }
            return isFinal ? $0.acc.finalize(text: text, at: now) : $0.acc.update(volatile: text, at: now)
        }
        eventCont.yield(.transcript(ev))
    }

    /// Finalize the volatile tail in place. Finalizes only through the end of the last result
    /// the analyzer produced, never through audio it has not decoded yet: finalizing through
    /// the end of *sent* audio made the analyzer emit punctuation-only finals for the speech
    /// that followed (probe runs 2 and 3, 2026-09-19). With `frequentFinalization` on the
    /// dictation module the analyzer finalizes on its own and this is rarely needed.
    public func commitSegment() async {
        let (a, through) = state.withLockUnchecked { ($0.analyzer, $0.lastResultEnd) }
        guard let a, through.isValid, through > .zero else { return }
        do { try await a.finalize(through: through) } catch { eventCont.yield(.error("finalize: \(error)")) }
    }

    public func stop() async {
        let (a, cont, task, already) = state.withLockUnchecked { s -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Bool) in
            let already = s.stopped
            s.stopped = true
            return (s.analyzer, s.inputCont, s.resultsTask, already)
        }
        if already { return }
        audio.stop()
        cont?.finish()
        if let a {
            // finalizeAndFinishThroughEndOfInput can block when the analyzer still holds
            // undecoded audio; bound it and fall back to cancelling.
            let finished = await finishesWithin(seconds: 2) { try? await a.finalizeAndFinishThroughEndOfInput() }
            if !finished {
                eventCont.yield(.status("stop: analyzer did not finish within 2 s, cancelling"))
                await a.cancelAndFinishNow()
            }
        }
        task?.cancel()
        eventCont.finish()
    }

    // MARK: Model assets

    static func ensureModel(for module: any SpeechModule, locale: Locale, installed: [Locale], supported: [Locale],
                            status: @Sendable (String) -> Void) async throws {
        let id = locale.identifier(.bcp47)
        guard supported.contains(where: { $0.identifier(.bcp47) == id }) else {
            throw SpeechProviderError.unavailable("locale \(locale.identifier) not supported by this module")
        }
        if installed.contains(where: { $0.identifier(.bcp47) == id }) { return }
        status("downloading speech model for \(locale.identifier)…")
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await req.downloadAndInstall()
            status("speech model installed")
        } else {
            throw SpeechProviderError.assetMissing("no installation request available for \(locale.identifier)")
        }
    }

    public static func assetStatus(locale: Locale = Locale(identifier: "en-US")) async -> (supported: Bool, installed: Bool) {
        let id = locale.identifier(.bcp47)
        let s = await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == id }
        let i = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == id }
        return (s, i)
    }

    public static func dictationAssetStatus(locale: Locale = Locale(identifier: "en-US")) async -> (supported: Bool, installed: Bool) {
        let id = locale.identifier(.bcp47)
        let s = await DictationTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == id }
        let i = await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == id }
        return (s, i)
    }
}
