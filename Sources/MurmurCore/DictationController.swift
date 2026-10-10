import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(latched: Bool)
    case processing
    /// Something went wrong. We still fail toward raw text where we can.
    case failed(String)
    /// Nothing went wrong, but there's something to do — the text is on the
    /// clipboard, waiting to be pasted. Not dressed as an error, because the
    /// words are safe.
    case notice(title: String, detail: String)

    public var isActive: Bool {
        switch self {
        case .recording, .processing: true
        case .idle, .failed, .notice: false
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
/// What became of the text. A sink that quietly falls back to the clipboard and
/// reports success is how a dictation ends up nowhere with nothing said about it.
public enum InsertOutcome: Equatable, Sendable {
    case typed
    /// Left on the clipboard, and why. Only ever for a permissions or settings
    /// reason — never as a guess about whether a paste landed.
    case copied(reason: String)
    /// Not typed anywhere, and why. The text is kept in the recent list.
    case notTyped(reason: String)
}

/// Carries a result out of a `Deadline.race` closure.
final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ text: String) { lock.lock(); stored = text; lock.unlock() }
}

/// One finished dictation, kept so it can be typed again on request.
public struct Transcript: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
    public init(text: String, date: Date = Date()) {
        id = UUID(); self.text = text; self.date = date
    }
}

public protocol TextSink: AnyObject {
    @discardableResult
    func insert(_ text: String) throws -> InsertOutcome
}

/// Wires hotkey → engine → sink and owns the state machine.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle {
        // The only thing allowed to arm Return-to-stop: the controller's own
        // state, which is the truth, rather than the key monitor's guess at it.
        didSet {
            if case .recording(latched: true) = state {
                hotkeys.returnStopsRecording = true
            } else {
                hotkeys.returnStopsRecording = false
            }
        }
    }

    /// Whether Return can stop a locked recording on this Mac.
    public var returnCanStop: Bool { hotkeys.canIntercept }
    @Published public private(set) var partialText: String = ""
    /// Smoothed input level, 0…1. The HUD animates from this.
    @Published public private(set) var level: Float = 0
    /// Where the HUD should sit — resolved when a capture starts.
    @Published public private(set) var anchor: CaretLocator.Anchor?
    /// Last thing we inserted — the raw/cleaned swap in M3 needs this.
    @Published public private(set) var lastTranscript: String = ""

    /// The last few dictations, newest first, in memory only. Whether a paste
    /// landed is not reliably knowable, so instead of guessing, the user can
    /// pick the one that went astray and have it typed again.
    @Published public private(set) var recent: [Transcript] = []
    public static let recentLimit = 10

    /// How long transcription may take before it is abandoned. Settable so the
    /// test can prove the bound without waiting eight seconds.
    public var engineDeadline: Double = 8

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
        switch state {
        case .idle:
            break
        case .failed, .notice:
            // A message about the *last* attempt must never block the next one.
            // It sat on screen for two seconds and swallowed every press in the
            // meantime, which reads exactly like the app having died.
            break
        case .recording, .processing:
            // Silence here is how a wedged state machine looked like a dead
            // hotkey: every press did nothing and said nothing.
            Log.echo("hotkey ignored — still \(state)")
            // And tell the key side, so it doesn't go on to "latch" a recording
            // that never started.
            hotkeys.abandonPress()
            return
        }

        // A focused password field kills our event tap and would make us look
        // broken. Say so instead.
        guard !Permissions.isSecureInputActive else {
            state = .failed("Disabled — a secure input field is focused")
            resetSoon()
            return
        }

        // Nothing to paste into means the whole dictation ends in nothing, so
        // don't start one. Only checked when we'd be typing into the app — in
        // clipboard mode there is always somewhere for the text to go.
        if FocusGatePreference.isEnabled, InsertionPreference.current == .typeIntoApp {
            let reading = FocusProbe.probe()
            // The lists can only be tuned against what real apps actually
            // report, and they disagree wildly. Recorded on anything other than
            // a plain text field so there's evidence to tune from.
            if reading.focus != .editable { Log.echo("focus: \(reading.description)") }
            if case .notEditable(let role) = reading.focus {
                Log.echo("declined — nothing focused to type into (\(role))")
                state = .failed("Click into a text field first")
                resetSoon()
                return
            }
        }

        do {
            partialText = ""
            level = 0
            anchor = nil
            captureGeneration &+= 1
            try engine.beginCapture()
            state = .recording(latched: false)
        } catch {
            state = .failed(error.localizedDescription)
            resetSoon()
            return
        }

        // Locating the caret is several synchronous cross-process accessibility
        // calls, and doing them before publishing `.recording` meant the HUD
        // could not draw until they finished — so it appeared only when the key
        // was released. Let the run loop paint first, then find the caret and
        // move the HUD to it.
        let generation = captureGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureGeneration == generation,
                  case .recording = self.state else { return }
            let located = CaretLocator.locate()
            // Which rung of the ladder we landed on decides where the HUD ends
            // up, so it belongs in the log — "I never see the popup" is
            // otherwise unanswerable.
            Log.echo("anchor: \(located.precision.rawValue)")
            self.anchor = located
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
                // Bounded on its own, well short of the overall watchdog: the
                // overall one has to allow for a twenty-second cleanup request,
                // and a stuck transcription should not cost the user that long.
                let engine = self.engine
                let box = TranscriptBox()
                let finishedInTime = await Deadline.race(seconds: engineDeadline) {
                    box.set((try? await engine.finishCapture()) ?? "")
                }
                if !finishedInTime {
                    Log.echo("engine: finish took over 8s — abandoning it")
                    engine.cancelCapture()
                }
                let transcript = box.value
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
                remember(text)
                apply(try sink.insert(text), for: text)
                partialText = ""
            } catch {
                Log.echo("FAILED: \(error)")
                state = .failed(error.localizedDescription)
                resetSoon()
            }
        }
    }

    /// What the popup says when the text went to the clipboard instead: what
    /// happened, then what to do. Paste is ⌘V on every Mac keyboard layout, so
    /// it's named outright.
    public static let copiedTitle = "Couldn't type that"
    public static let copiedDetail = "Copied to clipboard — press ⌘V to paste."

    private func remember(_ text: String) {
        recent.insert(Transcript(text: text), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// What the user sees after an insertion. Never silence: the words are safe
    /// either way, but if they are not where the user was looking, only the
    /// user can finish the job.
    private func apply(_ outcome: InsertOutcome, for text: String) {
        switch outcome {
        case .typed:
            Log.echo("inserted \(text.count) chars")
            state = .idle
        case .copied(let reason):
            Log.echo("copied to clipboard — \(reason)")
            state = .notice(title: Self.copiedTitle, detail: Self.copiedDetail)
            resetSoon(after: 5)
        case .notTyped(let reason):
            Log.echo("not typed — \(reason)")
            state = .failed("Couldn't type that — it's under the Murmur icon")
            resetSoon(after: 5)
        }
    }

    /// Types a recent dictation again, into whatever is focused now. Driven from
    /// the menu, so by the time this runs the menu has closed and focus is back
    /// with the user's app.
    public func insertAgain(_ transcript: Transcript) {
        switch state {
        case .idle, .failed, .notice: break
        case .recording, .processing: return
        }
        Log.echo("typing again: \(transcript.text.count) chars from \(transcript.date)")
        // The menu is still tearing down when the action fires; a paste sent
        // into that moment can go to nobody.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            do {
                self.apply(try self.sink.insert(transcript.text), for: transcript.text)
            } catch {
                Log.echo("typing again FAILED: \(error)")
                self.state = .failed(error.localizedDescription)
                self.resetSoon()
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
    /// Distinguishes this capture from the next, so late async work can tell
    /// whether it is still relevant.
    private var captureGeneration: UInt64 = 0

    private func cancel() {
        engine.cancelCapture()
        partialText = ""
        state = .idle
    }

    /// Longer for anything the user has to act on — two seconds is enough to
    /// notice a message but not enough to read one and do what it says.
    private func resetSoon(after seconds: Double = 2) {
        // Only the most recent message may clear itself. Without this, the
        // timer from an earlier, shorter message wipes a later one early — a
        // five-second "press ⌘V" cut down to one.
        resetGeneration &+= 1
        let generation = resetGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard generation == resetGeneration else { return }
            switch state {
            case .failed, .notice: state = .idle
            default: break
            }
        }
    }
    private var resetGeneration: UInt64 = 0
}
