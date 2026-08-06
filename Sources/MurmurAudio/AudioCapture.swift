import AVFoundation
import Foundation
import MurmurCore

public enum AudioError: LocalizedError {
    case engineUnavailable
    case formatUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: "Could not start the audio engine"
        case .formatUnsupported(let detail): "Unsupported audio format: \(detail)"
        }
    }
}

/// Microphone capture, resampled to whatever format the recogniser asks for.
///
/// Emits `AVAudioPCMBuffer` rather than raw floats because that's what
/// `SpeechAnalyzer` consumes directly; a Parakeet engine can pull
/// `floatChannelData` out of the same buffer.
///
/// Two things matter here beyond "get samples":
///
///  - **The engine stays warm.** Cold-starting AVAudioEngine costs 100–200ms,
///    a large slice of the latency budget. It's started once and left running;
///    `beginCapture()` only flips a flag.
///  - **Pre-roll.** A rolling ~300ms is always buffered, so the first syllable
///    isn't clipped when you press the key mid-word.
public final class AudioCapture {
    /// Called on the audio thread with converted buffers. Keep it cheap.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Peak amplitude (0…1) of each captured buffer. Drives the level meter, so
    /// the UI reacts to the actual voice rather than faking activity.
    public var onLevel: ((Float) -> Void)?

    private static let preRollSeconds: Double = 0.3

    /// Off by default — see `warmUp()`.
    public var useVoiceProcessing = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private let lock = NSLock()
    private var hasLoggedFirstBuffer = false
    private var hasLoggedConverterFailure = false
    private var peakLevel: Float = 0
    private var convertedFrames: AVAudioFrameCount = 0
    private var capturing = false
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    public init() {}

    public var isRunning: Bool { engine.isRunning }

    /// The format buffers will be delivered in. Set before `warmUp()`.
    /// Pass `nil` to deliver the hardware's own format untouched.
    public func setTargetFormat(_ format: AVAudioFormat?) {
        lock.lock()
        targetFormat = format
        converter = nil
        lock.unlock()
    }

    // MARK: - Engine lifecycle

    /// Start the engine and leave it running for the life of the app.
    public func warmUp() throws {
        guard !engine.isRunning else { return }

        let input = engine.inputNode

        // Apple's AEC and noise suppression, opt-in. It reshapes the input bus
        // on this hardware — a 3-channel mic array becomes 7 or 9 channels, and
        // the downmix through that layout is suspect. Correct audio matters more
        // than echo cancellation, so it's off until the level check proves the
        // signal survives it.
        if useVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                Log.echo("audio: voice processing unavailable — \(error.localizedDescription)")
            }
        }

        var inputFormat = input.outputFormat(forBus: 0)
        if let target = targetFormat, AVAudioConverter(from: inputFormat, to: target) == nil {
            Log.echo("audio: no converter from \(inputFormat.channelCount) ch — disabling voice processing")
            try? input.setVoiceProcessingEnabled(false)
            inputFormat = input.outputFormat(forBus: 0)
        }

        guard inputFormat.sampleRate > 0 else {
            throw AudioError.formatUnsupported("input reports a zero sample rate")
        }

        // Install with a nil format so the tap uses whatever the bus is actually
        // running. Enabling voice processing can change the input format out from
        // under us, and a tap installed with a now-stale format silently never
        // fires — which looks exactly like a broken microphone.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.echo("audio: engine failed to start — \(error)")
            throw AudioError.engineUnavailable
        }
        let targetDesc = targetFormat.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "passthrough"
        Log.echo("audio: engine warm · \(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch → \(targetDesc)")
    }

    public func shutDown() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Capture window

    /// Opens the capture window and returns the pre-roll — the audio captured
    /// just *before* the key went down. Feed it to the recogniser first.
    @discardableResult
    public func beginCapture() -> [AVAudioPCMBuffer] {
        lock.lock()
        capturing = true
        peakLevel = 0
        convertedFrames = 0
        let leading = preRoll
        preRoll.removeAll(keepingCapacity: true)
        preRollFrames = 0
        // Release before converting: convert() takes this same lock, and NSLock
        // is not recursive — holding it here deadlocks on the first keypress.
        lock.unlock()

        return leading.compactMap { convert($0) }
    }

    public func endCapture() {
        lock.lock()
        capturing = false
        preRoll.removeAll(keepingCapacity: true)
        preRollFrames = 0
        lock.unlock()
    }

    // MARK: - Tap

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if !hasLoggedFirstBuffer {
            hasLoggedFirstBuffer = true
            Log.echo("audio: first buffer · \(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch")
        }
        let preRollCapacity = AVAudioFrameCount(buffer.format.sampleRate * Self.preRollSeconds)
        lock.lock()
        let active = capturing
        if !active {
            // Idle: keep only a trailing window, in the *input* format. Converting
            // is deferred to beginCapture() so we don't burn CPU on audio we throw away.
            if let copy = buffer.deepCopy() {
                preRoll.append(copy)
                preRollFrames += copy.frameLength
                while preRollFrames > preRollCapacity, let first = preRoll.first {
                    preRoll.removeFirst()
                    preRollFrames -= first.frameLength
                }
            }
        }
        lock.unlock()

        guard active, let out = convert(buffer) else { return }
        measure(out)
        onBuffer?(out)
    }

    /// Peak amplitude of what we're actually sending on. If this stays at zero
    /// while you're speaking, the problem is upstream of the recogniser — a bad
    /// downmix or the wrong input device — not the model.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        let frames = Int(buffer.frameLength)
        if let data = buffer.floatChannelData {
            for i in 0..<frames { peak = max(peak, abs(data[0][i])) }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<frames { peak = max(peak, abs(Float(data[0][i]) / 32768)) }
        }
        lock.lock()
        peakLevel = max(peakLevel, peak)
        convertedFrames += buffer.frameLength
        lock.unlock()

        onLevel?(peak)
    }

    /// Peak level and duration seen since the capture window opened.
    public func levelReport() -> (peak: Float, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let rate = targetFormat?.sampleRate ?? 16_000
        return (peakLevel, Double(convertedFrames) / rate)
    }

    /// Resamples into the target format, or passes through when they match.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        let target = targetFormat
        var conv = converter
        if target != nil, conv == nil, target != buffer.format {
            conv = AVAudioConverter(from: buffer.format, to: target!)
            converter = conv
        }
        lock.unlock()

        guard let target else { return buffer }
        guard let conv else {
            if !hasLoggedConverterFailure {
                hasLoggedConverterFailure = true
                Log.echo("audio: NO CONVERTER \(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch → \(Int(target.sampleRate))Hz/\(target.channelCount)ch — dropping audio")
            }
            // Passing the wrong format on would feed the recogniser garbage and
            // it would never produce a result. Better to drop and be obvious.
            return nil
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            Log.audio.error("resample failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}

private extension AVAudioPCMBuffer {
    /// The tap reuses its buffer, so anything we hold on to has to be copied.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: Int(frameLength))
            }
            return copy
        }
        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
