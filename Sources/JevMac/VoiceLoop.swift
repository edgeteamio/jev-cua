import Foundation
import JevCore
import os

/// Feeds a recognizer into a CommandSession (plan Phase 3, section 9.5). Utterance boundaries
/// are decided by `UtteranceAssembler`; this class owns the tasks, the audio-level hint, and
/// pause. Text the session did not consume by a boundary is dropped: it was judged incomplete
/// or not a command, and the user stopped talking.
public final class VoiceLoop: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var listening = false
        public var utteranceId = ""
        public var text = ""
        public var isFinal = false
        public var micLoud = false
        /// Smoothed microphone RMS (0...~0.5), for level meters.
        public var level: Float = 0
    }

    private let provider: any SpeechProvider
    private let audio: AudioInput
    private let session: CommandSession
    private let onStatus: @Sendable (Status) -> Void
    public let loudThreshold: Float
    public let tickMs: Int

    private struct State {
        var status = Status()
        var assembler: UtteranceAssembler
        var paused = false
        var tasks: [Task<Void, Never>] = []
        var lastLevelPublish: TimeInterval = 0
        /// Room noise floor: follows the level down quickly and up slowly, so "loud" means louder
        /// than the room, not louder than a fixed number.
        var noiseFloor: Float = 0.005
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(provider: any SpeechProvider, audio: AudioInput, session: CommandSession, loudThreshold: Float = 0.015,
                utteranceGapMs: Int = 1500, tickMs: Int = 100, onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.provider = provider; self.audio = audio; self.session = session
        self.loudThreshold = loudThreshold; self.tickMs = tickMs
        self.onStatus = onStatus
        self.state = OSAllocatedUnfairLock(uncheckedState: State(assembler: UtteranceAssembler(gapMs: utteranceGapMs)))
    }

    public var status: Status { state.withLockUnchecked { $0.status } }
    public var isPaused: Bool { state.withLockUnchecked { $0.paused } }

    public func start() async throws {
        try await provider.start()
        let t1 = Task { [weak self] in
            guard let self else { return }
            for await ev in self.provider.events { await self.handle(ev) }
        }
        let t2 = Task { [weak self] in
            guard let self else { return }
            for await l in self.audio.levels { await self.handle(level: l) }
        }
        let t3 = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(self.tickMs))
                await self.tick()
            }
        }
        state.withLockUnchecked { $0.tasks = [t1, t2, t3]; $0.status.listening = true }
        publish()
    }

    public func stop() async {
        let tasks = state.withLockUnchecked { s -> [Task<Void, Never>] in let t = s.tasks; s.tasks = []; s.status.listening = false; return t }
        tasks.forEach { $0.cancel() }
        await provider.stop()
        publish()
    }

    /// Pause: audio still flows to the recognizer (keeps its clock), but revisions are not
    /// forwarded and in-flight work is cancelled. Resume starts a fresh utterance.
    public func setPaused(_ paused: Bool) async {
        let changed = state.withLockUnchecked { s -> Bool in
            guard s.paused != paused else { return false }
            s.paused = paused; s.status.listening = !paused
            return true
        }
        guard changed else { return }
        if paused { await session.cancelAll(reason: "paused") }
        await boundary(reason: paused ? "paused" : "resumed")
    }

    // MARK: Events

    private func handle(_ ev: SpeechEvent) async {
        guard case .transcript(let t) = ev else { return }
        let rev: TranscriptRevision? = state.withLockUnchecked { s in
            guard !s.paused else { return nil }
            let r = s.assembler.apply(segmentText: t.segmentText, isFinal: t.isFinal, at: t.at)
            s.status.text = s.assembler.text; s.status.isFinal = false; s.status.utteranceId = s.assembler.utteranceId
            return r
        }
        publish()
        if let rev { await session.handleTranscript(rev) }
    }

    private func handle(level: AudioLevel) async {
        let (loud, changed) = state.withLockUnchecked { s -> (Bool, Bool) in
            let f = s.noiseFloor
            s.noiseFloor = level.rms < f ? f + (level.rms - f) * 0.2 : f + (level.rms - f) * 0.004
            let loud = level.rms >= max(loudThreshold, s.noiseFloor * 3)
            if loud { s.assembler.noteLoud(at: level.at) }
            let was = s.status.micLoud; s.status.micLoud = loud
            // Fast attack, slow release, so the meter follows syllables without flicker.
            s.status.level = level.rms > s.status.level ? level.rms : s.status.level * 0.8 + level.rms * 0.2
            let due = level.at - s.lastLevelPublish >= 0.05
            if due || was != loud { s.lastLevelPublish = level.at }
            return (loud, was != loud || due)
        }
        if loud { await session.noteAudio(loudAt: level.at) }
        if changed { publish() }
    }

    private func tick() async {
        let now = Mono.now()
        // A finalized, briefly quiet utterance becomes a final revision (see UtteranceAssembler).
        let final: TranscriptRevision? = state.withLockUnchecked { s in
            guard !s.paused, let f = s.assembler.pendingFinal(now: now) else { return nil }
            s.status.isFinal = true
            return f
        }
        if let final { publish(); await session.handleTranscript(final) }
        await session.tick()
        let (close, hasText, allFinal, quiet) = state.withLockUnchecked { s in
            (s.assembler.shouldClose(now: now), !s.assembler.text.isEmpty, s.assembler.allFinal, s.assembler.quietMs(now: now))
        }
        guard hasText else { return }
        if close { await boundary(reason: "silence"); return }
        // A tail the recognizer has not finalized after the gap: ask it to (bounded; a no-op
        // for providers that finalize on their own). Never close an utterance around a volatile
        // tail, or its finalized copy would arrive as a new utterance and fire again.
        guard allFinal else {
            if quiet >= Double(state.withLockUnchecked { $0.assembler.gapMs }) { await provider.commitSegment() }
            return
        }
        let idle = await session.isIdle
        let consumed = await session.isConsumedEntirely
        if idle && consumed { await boundary(reason: "consumed") }
    }

    private func boundary(reason: String) async {
        let hadText = state.withLockUnchecked { s -> Bool in
            let t = s.assembler.close()
            s.status.text = ""; s.status.isFinal = false; s.status.utteranceId = s.assembler.utteranceId
            return !t.isEmpty
        }
        if hadText || reason == "paused" { await session.endUtterance(reason: reason) }
        publish()
    }

    private func publish() { onStatus(state.withLockUnchecked { $0.status }) }
}
