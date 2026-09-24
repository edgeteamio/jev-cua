import AVFoundation
import Foundation
import JevCore
import os

public struct AudioLevel: Sendable, Codable, Equatable {
    public let at: TimeInterval
    public let rms: Float
    public init(at: TimeInterval, rms: Float) { self.at = at; self.rms = rms }
}

/// Owns the AVAudioEngine input tap. One consumer gets PCM buffers on the audio thread; RMS
/// levels go out on a stream so silence detection can combine audio activity with transcript
/// stability (plan 9.5).
public final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    private let levelContinuation: AsyncStream<AudioLevel>.Continuation
    public let levels: AsyncStream<AudioLevel>
    private let mutedFlag = OSAllocatedUnfairLock(initialState: false)

    /// While muted the tap drops its buffers and reports silence, so spoken feedback and other
    /// output from this process never reach the recognizer (plan Phase 3).
    public var muted: Bool {
        get { mutedFlag.withLock { $0 } }
        set { mutedFlag.withLock { $0 = newValue } }
    }

    public init() {
        (levels, levelContinuation) = AsyncStream<AudioLevel>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// The input node's native format (what the tap delivers).
    public var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// Installs the tap. `onBuffer` runs on the audio thread; keep it cheap (convert and yield).
    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputError.noInputDevice
        }
        let cont = levelContinuation
        let muted = mutedFlag
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            if muted.withLock({ $0 }) { cont.yield(AudioLevel(at: Mono.now(), rms: 0)); return }
            cont.yield(AudioLevel(at: Mono.now(), rms: Self.rms(buffer)))
            onBuffer(buffer, when)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        levelContinuation.finish()
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }
}

public enum AudioInputError: Error, CustomStringConvertible {
    case noInputDevice
    case conversionFailed
    public var description: String {
        switch self {
        case .noInputDevice: "no audio input device (or microphone access denied)"
        case .conversionFailed: "audio format conversion failed"
        }
    }
}

/// Sample-rate and layout conversion from the mic format to the analyzer's preferred format.
/// Ported from Apple's WWDC25 SpeechAnalyzer sample (BufferConverter).
final class BufferConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }
        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw AudioInputError.conversionFailed }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw AudioInputError.conversionFailed
        }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        let status = converter.convert(to: out, error: &error) { _, statusPointer in
            defer { consumed = true }
            statusPointer.pointee = consumed ? .noDataNow : .haveData
            return consumed ? nil : buffer
        }
        guard status != .error else { throw AudioInputError.conversionFailed }
        return out
    }
}
