import AppKit
import AVFoundation
import Foundation
import MurmurCore

public enum AudioError: LocalizedError {
    case engineUnavailable
    case formatUnsupported(String)
    /// Every microphone tried refused to start. Names them, because "could not
    /// start the audio engine" gives the user nothing to act on.
    case noUsableMicrophone(tried: [String])

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: "Could not start the audio engine"
        case .formatUnsupported(let detail): "Unsupported audio format: \(detail)"
        case .noUsableMicrophone(let tried):
            if let only = tried.first, tried.count == 1 {
                "Couldn't record from “\(only)” — choose a microphone in Settings → General"
            } else {
                "Couldn't find a working microphone — choose one in Settings → General"
            }
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
///  - **The engine is opened on demand by default.** Keeping it warm saves the
///    ~100ms it costs to start, but holding the microphone open all day makes
///    macOS show its orange in-use indicator permanently — and that indicator is
///    telling the truth. `MicrophonePolicy` decides; on demand, `beginCapture()`
///    starts the engine and `endCapture()` closes it again.
///  - **Pre-roll.** While the engine is open a rolling ~600ms is buffered, so
///    the first syllable isn't clipped when you press the key mid-word — and so
///    the hotkey's arming delay can discard nothing. There is nothing to buffer
///    before an on-demand start, which is the cost of not holding the mic.
public final class AudioCapture {
    /// Called on the audio thread with converted buffers. Keep it cheap.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Peak amplitude (0…1) of each captured buffer. Drives the level meter, so
    /// the UI reacts to the actual voice rather than faking activity.
    public var onLevel: ((Float) -> Void)?

    /// Connecting, fallen back, or ready — called on the main thread.
    public var onMicrophoneStatus: ((MicrophoneStatus) -> Void)?

    /// How long a Bluetooth headset gets to switch into call mode before
    /// another microphone is used. Most take under two seconds.
    public var bluetoothPatience: TimeInterval = 3

    /// For tests: replaces opening a real device.
    public var deviceStarter: ((AudioInputDevice) throws -> Void)?

    /// The headset being waited on, if any.
    private var connecting: AudioInputDevice?
    private var connectGeneration: UInt64 = 0
    private var configChangeGeneration: UInt64 = 0
    /// A device that never came up during the last capture.
    public private(set) var failedToConnect: String?

    public var connectingDeviceName: String? { connecting?.name ?? awaitingAudioName }

    /// A Bluetooth headset that has started but not yet delivered audio. It
    /// counts as connecting until sound arrives: on real Pixel Buds the engine
    /// started at 1.2s but the first buffer came at 4.4s, after the headset had
    /// finished settling into call mode.
    private var awaitingAudioName: String? {
        lock.lock(); defer { lock.unlock() }
        return _awaitingAudioName
    }
    private var _awaitingAudioName: String?

    /// Must exceed the longest arming delay the hotkey offers (300ms), or the
    /// delay would start costing words instead of being free. The extra 300ms on
    /// top covers speaking a beat before pressing.
    private static let preRollSeconds: Double = 0.6


    /// The open microphone. A direct, input-only connection — see DeviceInput
    /// for why it isn't AVAudioEngine any more.
    private var input: DeviceInput?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private var configObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var healthTimer: Timer?
    private var rebuildAttempt = 0
    /// Our own record of a *successful* start. `engine.isRunning` can report true
    /// after `start()` has thrown, and trusting it turned one failed rebuild into
    /// permanent silence: every retry saw "running" and returned without a word.
    private var isWarm = false
    private var lastBufferAt = Date.distantPast

    private let lock = NSLock()
    private var hasLoggedFirstBuffer = false
    private var hasLoggedConverterFailure = false
    private var peakLevel: Float = 0
    private var convertedFrames: AVAudioFrameCount = 0
    private var capturing = false
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    public init() {}

    deinit {
        healthTimer?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    public var isRunning: Bool { isWarm }

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
    /// The microphone in use, once one has started.
    public private(set) var currentDevice: AudioInputDevice?

    /// For tests: the order to try, instead of asking the system.
    public var candidateOverride: [AudioInputDevice]?

    /// Starts on the first microphone that will actually start.
    ///
    /// Murmur used to use the macOS default input and nothing else. A dock's own
    /// audio chip often becomes the default when it's plugged in — usually an
    /// input jack with nothing in it — and then dictation simply didn't work.
    public func warmUp() throws {
        guard !isWarm, connecting == nil else { return }
        failedToConnect = nil
        let candidates = candidateOverride ?? AudioDevices.candidates(
            preferredUID: MicrophoneChoice.selectedUID,
            defaultID: AudioDevices.defaultInputID(),
            devices: AudioDevices.inputs()
        )
        // If CoreAudio can't be asked, fall back to the old behaviour rather
        // than refuse outright.
        guard !candidates.isEmpty else { return try start(on: nil) }

        try startFirstWorking(candidates, tried: [])
    }

    private func startFirstWorking(_ candidates: [AudioInputDevice], tried: [String]) throws {
        var tried = tried
        for (index, device) in candidates.enumerated() {
            do {
                try startDevice(device)
                if let first = tried.first {
                    Log.echo("audio: fell back to “\(device.name)” after \(tried.map { "“\($0)”" }.joined(separator: ", ")) failed")
                    report(.fellBack(from: first, to: device.name))
                } else if device.transport == .bluetooth {
                    report(.connecting(device.name))
                } else {
                    report(.ready)
                }
                return
            } catch {
                Log.echo("audio: “\(device.name)” (\(device.transport.rawValue)) wouldn't start — \(error.localizedDescription)")
                if device.transport == .bluetooth {
                    // Not broken — switching. Opening a Bluetooth headset's
                    // microphone makes macOS move it from music mode into call
                    // mode, and until that finishes it can't be started. Falling
                    // straight back meant a headset never got the chance.
                    waitForBluetooth(device, then: Array(candidates.dropFirst(index + 1)), tried: tried + [device.name])
                    return
                }
                tried.append(device.name)
            }
        }
        throw AudioError.noUsableMicrophone(tried: tried)
    }

    private func startDevice(_ device: AudioInputDevice) throws {
        if let deviceStarter {
            try deviceStarter(device)
            isWarm = true
            currentDevice = device
            noteBuffer()
        } else {
            try start(on: device)
        }
        if device.transport == .bluetooth {
            lock.lock(); _awaitingAudioName = device.name; lock.unlock()
        }
    }

    /// For tests: what the first buffer from the device would do.
    public func simulateFirstAudio() { firstAudioArrived() }

    /// For tests: hands a buffer to the same path the device's buffers take.
    public func simulateIncoming(_ buffer: AVAudioPCMBuffer) { handle(buffer) }

    /// Whether a buffer holds anything but exact zeros. Only exact zeros count
    /// as silence: a quiet room still reads around 0.0004, and a live mic never
    /// produces a run of perfect zeros.
    static func carriesSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return true }
        let frames = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            let d = channels[c]
            for i in 0..<frames where d[i] != 0 { return true }
        }
        return false
    }

    private func firstAudioArrived() {
        lock.lock()
        let was = _awaitingAudioName
        _awaitingAudioName = nil
        lock.unlock()
        guard let was else { return }
        Log.echo("audio: “\(was)” is delivering sound")
        report(.ready)
    }

    /// Retries a Bluetooth headset until it's in call mode, without holding up
    /// the dictation: capture is already open and buffers flow the moment it
    /// starts. Gives up after `bluetoothPatience` and moves to the next one.
    private func waitForBluetooth(_ device: AudioInputDevice, then remaining: [AudioInputDevice], tried: [String]) {
        connecting = device
        connectGeneration &+= 1
        let generation = connectGeneration
        let startedAt = Date()
        report(.connecting(device.name))
        Log.echo("audio: waiting for “\(device.name)” to switch into headset mode")
        retryBluetooth(device, remaining: remaining, tried: tried, generation: generation, startedAt: startedAt)
    }

    private func retryBluetooth(
        _ device: AudioInputDevice, remaining: [AudioInputDevice], tried: [String],
        generation: UInt64, startedAt: Date
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.connectGeneration, self.connecting != nil else { return }
            do {
                try self.startDevice(device)
                self.connecting = nil
                // Started, but stays "connecting" until sound actually arrives.
                Log.echo(String(format: "audio: “%@” started after %.1fs", device.name, Date().timeIntervalSince(startedAt)))
            } catch {
                guard Date().timeIntervalSince(startedAt) < self.bluetoothPatience else {
                    self.connecting = nil
                    self.failedToConnect = device.name
                    Log.echo("audio: “\(device.name)” didn't come up in \(Int(self.bluetoothPatience))s — trying the next microphone")
                    do {
                        try self.startFirstWorking(remaining, tried: tried)
                    } catch {
                        Log.echo("audio: no microphone would start — \(error.localizedDescription)")
                    }
                    return
                }
                self.retryBluetooth(device, remaining: remaining, tried: tried, generation: generation, startedAt: startedAt)
            }
        }
    }

    private func report(_ status: MicrophoneStatus) {
        let callback = onMicrophoneStatus
        if Thread.isMainThread { callback?(status) } else { DispatchQueue.main.async { callback?(status) } }
    }

    private func start(on device: AudioInputDevice?) throws {
        let startedAt = Date()
        closeInput()

        // Nil means "whatever macOS has as the default input" — used only when
        // the device list can't be read at all.
        guard let deviceID = device?.id ?? AudioDevices.defaultInputID() else {
            throw AudioError.noUsableMicrophone(tried: [])
        }
        let opened: DeviceInput
        do {
            opened = try DeviceInput(
                deviceID: deviceID,
                onBuffer: { [weak self] buffer in self?.handle(buffer) },
                // Called on a CoreAudio queue; the decision happens on main.
                onChange: { [weak self] in
                    DispatchQueue.main.async { self?.configurationChanged() }
                }
            )
        } catch {
            Log.echo("audio: couldn't open the microphone — \(error.localizedDescription)")
            throw AudioError.engineUnavailable
        }
        input = opened
        lock.lock()
        converter = nil
        hasLoggedConverterFailure = false
        lock.unlock()

        isWarm = true
        currentDevice = device
        noteBuffer()
        let inputFormat = opened.format
        let targetDesc = targetFormat.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "passthrough"
        // Which microphone, by name — the first thing to know when someone
        // says it doesn't work on their setup.
        let which = device.map { " · “\($0.name)” (\($0.transport.rawValue))" } ?? " · system default"
        Log.echo(String(
            format: "audio: engine open in %.0fms · %dHz/%dch → %@%@",
            Date().timeIntervalSince(startedAt) * 1000,
            Int(inputFormat.sampleRate), Int(inputFormat.channelCount), targetDesc, which
        ))

        observeInterruptions()
        startHealthWatch()
    }

    private func closeInput() {
        input?.stop()
        input = nil
    }

    /// Buffers arrive every ~21ms whenever the engine is healthy, so a long gap
    /// is the one symptom every silent-death mode has in common — a failed
    /// rebuild, a device that vanished, an interruption nobody told us about.
    /// Rather than enumerate the causes, watch for the symptom.
    private func startHealthWatch() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.isWarm else { return }
            let quiet = Date().timeIntervalSince(self.lastBuffer)
            guard quiet > 8 else { return }
            Log.echo(String(format: "audio: no buffers for %.0fs", quiet))
            self.restart(reason: "input went quiet")
        }
    }

    /// Whether we should be holding the microphone at all right now.
    private var wantsMicrophone: Bool {
        if MicrophonePreference.current == .alwaysOpen { return true }
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    /// A headset switching into call mode posts several of these, and so does
    /// switching back. Rebuilding on each one tried the headset again before it
    /// had settled, which failed, which posted another — a loop that ran six
    /// times in two seconds and left a dictation with no audio at all.
    func configurationChanged() {
        // Only meaningful while we hold the microphone. Rebuilding when idle
        // would open it — exactly what the on-demand policy exists to avoid.
        // And a headset still switching is expected to make these.
        guard isWarm, connecting == nil else { return }
        configChangeGeneration &+= 1
        let generation = configChangeGeneration
        // A headset that's started but silent is still settling into call mode,
        // and each settling step stops the engine. Waiting the usual 0.6s for
        // more notices only added to the silence; 0.25s still coalesces them.
        let settle: TimeInterval = awaitingAudioName != nil ? 0.25 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, generation == self.configChangeGeneration,
                  self.isWarm, self.connecting == nil, self.wantsMicrophone else { return }
            // Still hearing? Then the change didn't stop it.
            if Date().timeIntervalSince(self.lastBuffer) < 0.4 { return }
            self.restart(reason: "hardware configuration changed")
        }
    }

    /// Test entry: what the system's change notice would do.
    public func simulateConfigurationChange() { configurationChanged() }

    private var lastBuffer: Date {
        lock.lock(); defer { lock.unlock() }
        return lastBufferAt
    }

    private func noteBuffer() {
        lock.lock()
        lastBufferAt = Date()
        lock.unlock()
    }

    /// Use the microphone chosen in Settings now, if the engine is open. When
    /// it isn't, the next dictation picks it up anyway.
    public func reselectMicrophone() {
        guard isWarm else { return }
        restart(reason: "microphone changed in Settings")
    }

    public func shutDown() {
        connecting = nil
        lock.lock(); _awaitingAudioName = nil; lock.unlock()
        connectGeneration &+= 1
        configChangeGeneration &+= 1
        healthTimer?.invalidate()
        healthTimer = nil
        guard isWarm else { return }
        closeInput()
        isWarm = false
    }

    // MARK: - Surviving the day

    /// The engine does not in fact run for the life of the app. macOS stops it
    /// and invalidates every tap whenever the audio hardware changes underneath
    /// it — headphones in or out, a display with a mic plugged in, a Bluetooth
    /// device connecting, waking from sleep. Nothing is thrown and `isRunning`
    /// can still read true; buffers simply stop arriving, which is
    /// indistinguishable from a broken microphone.
    private func observeInterruptions() {
        // Device changes — unplugged, changing rate, a headset settling — are
        // reported by DeviceInput's own listeners on the device itself.

        // Once per process. Adding it on every start would stack up handlers
        // and restart once per handler on every wake.
        guard wakeObserver == nil else { return }
        // Waking doesn't always post a configuration change, and a tap that
        // slept through a suspend can come back mute.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isWarm else { return }
            self.restart(reason: "woke from sleep")
        }
    }

    /// Tears the engine down and warms it again from scratch. Cheaper than the
    /// alternative, which is a menu bar icon that looks fine and hears nothing.
    public func restart(reason: String) {
        rebuildAttempt = 0
        rebuild(reason: reason)
    }

    private func rebuild(reason: String) {
        Log.echo("audio: \(reason) — rebuilding engine (attempt \(rebuildAttempt + 1))")

        lock.lock()
        let wasCapturing = capturing
        hasLoggedFirstBuffer = false
        converter = nil
        preRoll.removeAll()
        preRollFrames = 0
        // Not a real buffer, but it stops the health watch piling more rebuilds
        // on top of this one while it's in progress.
        lastBufferAt = Date()
        lock.unlock()

        closeInput()
        isWarm = false

        do {
            try warmUp()
            rebuildAttempt = 0
            lock.lock()
            capturing = wasCapturing
            lock.unlock()
        } catch {
            // Hardware in flux — a device arriving or leaving — reports formats
            // that can't be started for a moment. One retry was not enough: it is
            // the difference between recovering and being deaf until relaunch.
            rebuildAttempt += 1
            guard rebuildAttempt <= 8 else {
                Log.echo("audio: gave up after \(rebuildAttempt) attempts — no microphone until relaunch")
                return
            }
            let delay = min(pow(2, Double(rebuildAttempt - 1)) * 0.5, 15)
            Log.echo(String(
                format: "audio: rebuild failed (%@) — retrying in %.1fs",
                error.localizedDescription, delay
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wantsMicrophone else { return }
                self.rebuild(reason: "retry")
            }
        }
    }

    // MARK: - Capture window

    /// Opens the capture window and returns the pre-roll — the audio captured
    /// just *before* the key went down. Feed it to the recogniser first.
    ///
    /// Throws only when the microphone can't be opened, which under the
    /// on-demand policy is now discovered here rather than at launch.
    @discardableResult
    public func beginCapture() throws -> [AVAudioPCMBuffer] {
        if !isWarm { try warmUp() }

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

        // Give the microphone back. The orange indicator going out is the whole
        // point of the on-demand policy, so this must not be deferred or
        // batched — it happens the moment the key is released.
        if MicrophonePreference.current == .onDemand { shutDown() }
    }

    // MARK: - Tap

    private func handle(_ buffer: AVAudioPCMBuffer) {
        noteBuffer()
        // Frames arriving isn't the same as the microphone being live. AirPods
        // deliver about 0.65s of exact digital zeros after they start, while
        // they finish switching into call mode — measured three times on real
        // AirPods Pro, every time. Saying "Listening" at the first frame told
        // the user to talk into that gap, and their first few words were lost.
        // Real microphones always carry some noise, so the first nonzero sample
        // is the moment it's actually listening.
        if awaitingAudioName != nil, Self.carriesSignal(buffer) {
            DispatchQueue.main.async { [weak self] in self?.firstAudioArrived() }
        }
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
        // Remade whenever the input changes shape — a headset switching into
        // call mode changes its rate mid-session.
        if let target, buffer.format != target, conv == nil || conv?.inputFormat != buffer.format {
            conv = AVAudioConverter(from: buffer.format, to: target)
            converter = conv
        }
        lock.unlock()

        guard let target else { return buffer }
        // Already exactly what the recogniser wants — which is what a Bluetooth
        // headset in call mode delivers. This case used to fall through to "no
        // converter" and drop every buffer.
        if buffer.format == target { return buffer }
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
