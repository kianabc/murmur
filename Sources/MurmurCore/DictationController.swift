import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(latched: Bool)
    case processing
    /// Something went wrong. We still fail toward raw text where we can.
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .recording, .processing: true
        case .idle, .failed: false
        }
    }
}

/// Produces a transcript from captured audio.
public protocol DictationEngine: AnyObject {
    func beginCapture() throws
    func cancelCapture()
    /// Stop capturing and return the raw transcript. Cleanup happens later (M3).
    func finishCapture() async throws -> String
    /// Live partial text for the popup, if the engine streams.
    var onPartial: ((String) -> Void)? { get set }
    /// Live input level (0…1) for the meter.
    var onLevel: ((Float) -> Void)? { get set }
}

/// Puts text into whatever app is frontmost.
public protocol TextSink: AnyObject {
    func insert(_ text: String) throws
}

/// Wires hotkey → engine → sink and owns the state machine.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var partialText: String = ""
    /// Smoothed input level, 0…1. The HUD animates from this.
    @Published public private(set) var level: Float = 0
    /// Where the HUD should sit — resolved when a capture starts.
    @Published public private(set) var anchor: CaretLocator.Anchor?
    /// Last thing we inserted — the raw/cleaned swap in M3 needs this.
    @Published public private(set) var lastTranscript: String = ""

    private let hotkeys: HotkeyMonitor
    private let engine: DictationEngine
    private let sink: TextSink
    private let permissions = Permissions()

    /// Runs on the raw transcript before insertion. Learned corrections live
    /// here today; the LLM cleanup pass (M3) will chain in behind them.
    public var postProcess: ((String) async -> String)?

    /// The last raw transcript, before post-processing — what the revert hotkey
    /// restores, and the baseline the post-paste learner diffs against.
    @Published public private(set) var lastRawTranscript: String = ""

    public init(engine: DictationEngine, sink: TextSink, hotkeys: HotkeyMonitor = HotkeyMonitor()) {
        self.engine = engine
        self.sink = sink
        self.hotkeys = hotkeys

        self.engine.onPartial = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        self.engine.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                // Attack fast, decay slow — a meter that drops instantly reads
                // as broken; one that lags reads as alive.
                self.level = value > self.level
                    ? value
                    : self.level * 0.82 + value * 0.18
            }
        }
        self.hotkeys.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    @discardableResult
    public func startListening() -> Bool {
        hotkeys.start()
    }

    public func stopListening() {
        hotkeys.stop()
    }

    public var isListening: Bool { hotkeys.isRunning }

    public var hotkey: Hotkey { hotkeys.hotkey }

    /// Change the trigger key. Takes effect immediately.
    public func setHotkey(_ hotkey: Hotkey) {
        hotkeys.setHotkey(hotkey)
    }

    // MARK: - Manual control (no Input Monitoring needed)

    /// Start dictating without the global hotkey. Driven by a button or menu
    /// item, so it needs no Input Monitoring — which makes the whole pipeline
    /// testable with only the microphone permission.
    public func startManual() { begin() }
    public func stopManual() { finish() }
    public func cancelManual() { cancel() }

    public func toggleManual() {
        if case .recording = state { finish() } else { begin() }
    }

    // MARK: - State machine

    private func handle(_ event: HotkeyEvent) {
        Log.echo("hotkey: \(event)")
        switch event {
        case .begin: begin()
        case .latch: latch()
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard case .idle = state else {
            // Silence here is how a wedged state machine looked like a dead
            // hotkey: every press did nothing and said nothing.
            Log.echo("hotkey ignored — still \(state)")
            return
        }

        // A focused password field kills our event tap and would make us look
        // broken. Say so instead.
        guard !Permissions.isSecureInputActive else {
            state = .failed("Disabled — a secure input field is focused")
            resetSoon()
            return
        }

        do {
            partialText = ""
            level = 0
            // Resolve once per capture: chasing the caret mid-sentence would make
            // the HUD jitter as the text grows.
            anchor = CaretLocator.locate()
            try engine.beginCapture()
            state = .recording(latched: false)
        } catch {
            state = .failed(error.localizedDescription)
            resetSoon()
        }
    }

    private func latch() {
        guard case .recording = state else { return }
        state = .recording(latched: true)
    }

    private func finish() {
        guard case .recording = state else { return }
        state = .processing

        // Nothing downstream is allowed to strand the state machine. Even with
        // every await bounded, one unbounded path is enough to leave the app
        // permanently deaf with no way back short of relaunching it.
        //
        // 45s sits well clear of the worst legitimate case (2s analyzer start +
        // 3s drain + 20s cleanup request), so this only fires on a real hang and
        // never races a slow-but-working dictation.
        let generation = processingGeneration &+ 1
        processingGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.processingGeneration == generation,
                  case .processing = self.state else { return }
            Log.echo("finish never returned — releasing the state machine")
            self.engine.cancelCapture()
            self.state = .failed("Dictation timed out — try again")
            self.partialText = ""
            self.resetSoon()
        }

        Task { @MainActor in
            do {
                let transcript = try await engine.finishCapture()
                let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    // Silently returning to idle is indistinguishable from a
                    // broken hotkey. Say that nothing was heard.
                    Log.echo("no speech detected — nothing to insert")
                    state = .failed("Didn't catch that — try speaking a little louder")
                    partialText = ""
                    resetSoon()
                    return
                }
                lastRawTranscript = raw

                let text = await postProcess?(raw) ?? raw
                lastTranscript = text
                try sink.insert(text)
                Log.echo("inserted \(text.count) chars")
                state = .idle
                partialText = ""
            } catch {
                Log.echo("FAILED: \(error)")
                state = .failed(error.localizedDescription)
                resetSoon()
            }
        }
    }

    /// Surface a problem in the HUD without discarding the text that was just
    /// inserted — the transcript is fine, something downstream isn't.
    public func reportProblem(_ message: String) {
        state = .failed(message)
        resetSoon()
    }

    /// Guards the watchdog against firing on a later, healthy capture.
    private var processingGeneration: UInt64 = 0

    private func cancel() {
        engine.cancelCapture()
        partialText = ""
        state = .idle
    }

    private func resetSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if case .failed = state { state = .idle }
        }
    }
}
