import AVFoundation
import Foundation
import JevCore
import os

/// Spoken feedback (plan Phase 3, folded in from Laya): short phrases on dispatch and on
/// failure, nothing on routine success. Mutes the microphone while speaking plus a short
/// tail so the recognizer never hears this process. Toggleable; `enabled` defaults to the
/// `spokenFeedback` user default (true).
public final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let defaultsKey = "spokenFeedback"
    public static var enabledByDefault: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private let synth = AVSpeechSynthesizer()
    private let audio: AudioInput?
    private let state = OSAllocatedUnfairLock(initialState: (enabled: true, speaking: 0, generation: 0))
    public let tailMs: Int

    public init(audio: AudioInput?, enabled: Bool = Speaker.enabledByDefault, tailMs: Int = 300) {
        self.audio = audio
        self.tailMs = tailMs
        super.init()
        state.withLock { $0.enabled = enabled }
        synth.delegate = self
    }

    public var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            state.withLock { $0.enabled = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if !newValue { synth.stopSpeaking(at: .immediate) }
        }
    }

    public var isSpeaking: Bool { state.withLock { $0.speaking > 0 } }

    /// Speaks `text`, replacing anything queued: feedback is about the latest event only.
    public func say(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        u.prefersAssistiveTechnologySettings = false
        audio?.muted = true
        let gen = state.withLock { s -> Int in s.speaking += 1; s.generation += 1; return s.generation }
        synth.speak(u)
        // Watchdog: a synthesizer that never reports back must not leave the mic muted.
        Task { [state, audio] in
            try? await Task.sleep(for: .seconds(8))
            let stuck = state.withLock { $0.speaking > 0 && $0.generation == gen }
            if stuck { state.withLock { $0.speaking = 0 }; audio?.muted = false }
        }
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func finished() {
        let gen = state.withLock { s -> Int in
            s.speaking = max(0, s.speaking - 1); s.generation += 1; return s.generation
        }
        guard let audio else { return }
        // Keep the mic muted for the tail so the room's echo of the last syllable is dropped.
        Task { [state, tailMs] in
            try? await Task.sleep(for: .milliseconds(tailMs))
            let stillIdle = state.withLock { $0.speaking == 0 && $0.generation == gen }
            if stillIdle { audio.muted = false }
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }

    /// What to say for a session event; nil for silence. Only decision points that need the
    /// user (plan Phase 3): never on a routine dispatch, because the mic is muted while speaking
    /// and an early fire happens mid-sentence ("open notes | and create a new note").
    public static func phrase(for event: SessionEvent) -> String? {
        switch event {
        case .dispatched: return nil
        case .executed(_, let o):
            switch o.verification.outcome {
            case .failed: return "That did not work"
            default: return nil
            }
        case .pendingConfirmation(let c):
            guard let c else { return nil }
            return "Say confirm to \(c.action.summary.lowercased())"
        case .cancelled(let reason):
            return reason == "kill phrase" ? "Stopped" : nil
        case .decided(let d, let summary, _):
            // Waits that need the user: no field focused, deny list.
            switch d.outcome {
            case .ignore(let reason) where reason.hasPrefix("denied"): return "I will not do that"
            case .wait(let reason, _) where reason == "no field focused": return "No text field is focused"
            default: return nil
            }
        case .disambiguation(let els):
            guard let els, !els.isEmpty else { return nil }
            return "Which one? Say a number, one to \(els.count)"
        case .transcript, .deciding, .error: return nil
        }
    }
}
