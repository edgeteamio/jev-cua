import AVFoundation
import Foundation
import JevCore
import Speech
import os

/// SFSpeechRecognizer with on-device recognition required. The fallback provider; one
/// recognition task per segment, restarted after each final result.
public final class SFSpeechProvider: SpeechProvider, @unchecked Sendable {
    public let name = "SFSpeechRecognizer"
    public let events: AsyncStream<SpeechEvent>

    private let eventCont: AsyncStream<SpeechEvent>.Continuation
    private let audio: AudioInput
    private let recognizer: SFSpeechRecognizer

    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var acc = TranscriptAccumulator()
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(audio: AudioInput, locale: Locale = Locale(identifier: "en-US")) throws {
        self.audio = audio
        guard let r = SFSpeechRecognizer(locale: locale) else {
            throw SpeechProviderError.unavailable("SFSpeechRecognizer has no recognizer for \(locale.identifier)")
        }
        recognizer = r
        (events, eventCont) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() async throws {
        let status = await Permissions.requestSpeech()
        guard status == .authorized else { throw SpeechProviderError.notAuthorized(status.rawValue) }
        guard recognizer.isAvailable else { throw SpeechProviderError.unavailable("recognizer not available") }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechProviderError.unavailable("on-device recognition not supported for this locale")
        }
        startTask()
        try audio.start { [weak self] buffer, _ in
            self?.state.withLockUnchecked { $0.request }?.append(buffer)
        }
        eventCont.yield(.status("SFSpeechRecognizer listening (on-device)"))
    }

    private func startTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        state.withLockUnchecked { $0.request = req }
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        state.withLockUnchecked { $0.task = t }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        let now = Mono.now()
        if let result {
            let text = result.bestTranscription.formattedString
            let (ev, restart) = state.withLockUnchecked { s -> (TranscriptEvent, Bool) in
                let ev = result.isFinal ? s.acc.finalize(text: text, at: now) : s.acc.update(volatile: text, at: now)
                return (ev, result.isFinal && !s.stopped)
            }
            eventCont.yield(.transcript(ev))
            if restart { startTask() }
        }
        if let error {
            let restart = state.withLockUnchecked { !$0.stopped }
            let ns = error as NSError
            // 1110 = no speech detected; 216/301 = cancelled. Both are routine between segments.
            if ![1110, 216, 301].contains(ns.code) {
                eventCont.yield(.error("recognizer: \(ns.domain) \(ns.code) \(ns.localizedDescription)"))
            }
            if restart { startTask() }
        }
    }

    public func commitSegment() async {
        // The final result arrives in the handler, which starts a new task.
        state.withLockUnchecked { $0.request }?.endAudio()
    }

    public func stop() async {
        let (req, task, already) = state.withLockUnchecked { s -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, Bool) in
            let already = s.stopped
            s.stopped = true
            return (s.request, s.task, already)
        }
        if already { return }
        audio.stop()
        req?.endAudio()
        task?.cancel()
        eventCont.finish()
    }

    public static func status(locale: Locale = Locale(identifier: "en-US")) -> (available: Bool, onDevice: Bool) {
        guard let r = SFSpeechRecognizer(locale: locale) else { return (false, false) }
        return (r.isAvailable, r.supportsOnDeviceRecognition)
    }
}
