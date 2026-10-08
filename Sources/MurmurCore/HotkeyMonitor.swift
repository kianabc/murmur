import AppKit
import CoreGraphics

public enum HotkeyEvent: Sendable {
    /// Key went down — start capturing.
    case begin
    /// Hold released, or latch ended. Process what we captured.
    case finish
    /// Double-tap detected — keep recording until the next tap.
    case latch
    /// Esc. Throw it away.
    case cancel
}

/// Watches the dictation key globally via a CGEventTap.
///
/// Semantics (SPEC.md §3.1):
///   hold key         → record while held, process on release
///   double-tap       → latch on; next tap ends it
///   Esc while active → cancel, insert nothing
///
/// A modifier trigger is ambiguous: ⌥ alone means dictate, ⌥⌦ means delete a
/// word, ⌘⌥ means something else entirely. Two rules separate them — a press
/// arriving with another modifier already held is never a dictation, and a press
/// must survive an arming delay untouched by any other key before it counts.
/// Neither costs audio: `AudioCapture` keeps a rolling pre-roll, so the words
/// spoken during the delay are already in the buffer when recording opens.
///
/// The tap is `.listenOnly`: we observe events but never swallow them, so a bug
/// here can't break the user's keyboard.
///
/// Threading: the tap callback runs on its own thread and does nothing but
/// classify the event and hop to main. All state lives on the main actor, so
/// there is no shared mutable state to race on.
public final class HotkeyMonitor {
    public var onEvent: ((HotkeyEvent) -> Void)?

    public private(set) var hotkey: Hotkey

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Main-thread only.
    private var keyIsDown = false
    private var isRecording = false
    private var isLatched = false
    private var pressStarted: CFAbsoluteTime = 0
    private var doubleTapTimer: Timer?
    /// Running while a press waits to prove it's a bare hold rather than a chord.
    private var armTimer: Timer?
    /// This press turned out to be part of a combination — ignore its release.
    private var pressDisqualified = false
    /// When the last press-and-release shorter than the arming delay ended.
    private var lastTapEnded: CFAbsoluteTime = 0

    /// A press at least this long is an intentional hold, not half a double-tap.
    private let holdThreshold: TimeInterval = 0.25
    /// How long to wait for a second tap before treating the first as a real (tiny) dictation.
    private let doubleTapWindow: TimeInterval = 0.3

    private static let escKeyCode: Int64 = 53
    /// Return on the main keyboard, and Enter on a numeric keypad.
    private static let returnKeyCodes: Set<Int64> = [36, 76]

    /// Whether Return should stop the recording instead of reaching the app.
    ///
    /// Set by the controller from its own state — `.recording(latched: true)`
    /// and nothing else — rather than by this monitor's view of things, because
    /// the two have disagreed before, and a monitor that wrongly believed it was
    /// latched would eat every Return on the Mac. Read on the event tap's thread,
    /// so it sits behind a lock and the read is the only work done there.
    public var returnStopsRecording: Bool {
        get { swallowLock.lock(); defer { swallowLock.unlock() }; return swallowReturn }
        set { swallowLock.lock(); swallowReturn = newValue; swallowLock.unlock() }
    }
    private let swallowLock = NSLock()
    private var swallowReturn = false
    /// A Return keyDown was swallowed; swallow its keyUp too, so the app never
    /// sees half a keystroke.
    private var pendingReturnUp = false

    /// Whether the tap can intercept at all. Intercepting needs Accessibility;
    /// without it the tap falls back to listening, the shortcut still works, and
    /// Return simply isn't offered as a way to stop.
    public private(set) var canIntercept = false

    /// Caps lock is deliberately absent — it is not a chording modifier.
    private static let chordFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    /// 0 for a function key, which has nothing to disambiguate.
    private var armDelay: TimeInterval { HoldDelayPreference.current(for: hotkey) }

    public init(hotkey: Hotkey = HotkeyPreference.current) {
        self.hotkey = hotkey
    }

    /// Swap the trigger key. Restarts the tap if it's running.
    public func setHotkey(_ hotkey: Hotkey) {
        guard hotkey != self.hotkey else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        self.hotkey = hotkey
        HotkeyPreference.current = hotkey
        if wasRunning { start() }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if monitor.shouldSwallow(type: type, event: event) { return nil }
            monitor.classify(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        // Prefer a tap that can intercept, so Return can stop a locked recording
        // without also reaching the app — where it would send a chat message
        // before the dictation had been pasted into it. Without Accessibility
        // that tap can't be made; fall back to listening rather than lose the
        // shortcut altogether.
        var created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: context
        )
        canIntercept = created != nil
        if created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: context
            )
        }
        guard let tap = created else {
            // Almost always means Input Monitoring hasn't been granted.
            return false
        }
        Log.echo("hotkey: tap \(canIntercept ? "can intercept Return" : "listen-only (no Accessibility)")")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        Log.hotkey.info("listening for \(self.hotkey.displayName, privacy: .public)")
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        DispatchQueue.main.async { self.resetState() }
    }

    public var isRunning: Bool { tap != nil }

    // MARK: - Tap thread: classify only, never touch state

    /// Runs on the tap thread for every key on the Mac, so it does nothing but
    /// compare a key code and read one flag.
    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        guard canIntercept, type == .keyDown || type == .keyUp else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.returnKeyCodes.contains(keyCode) else { return false }

        swallowLock.lock()
        defer { swallowLock.unlock() }
        if type == .keyUp {
            if pendingReturnUp { pendingReturnUp = false; return true }
            return false
        }
        guard swallowReturn else { return false }
        swallowReturn = false
        pendingReturnUp = true
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat {
            DispatchQueue.main.async { self.returnPressed() }
        }
        return true
    }

    private func classify(type: CGEventType, event: CGEvent) {
        // The system disables a tap that takes too long or gets interrupted.
        // Re-arm rather than silently going dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == Self.escKeyCode, type == .keyDown {
            DispatchQueue.main.async { self.escPressed() }
            return
        }

        if let target = hotkey.keyCode {
            // Regular key: explicit down/up. Ignore auto-repeat.
            guard keyCode == Int64(target) else {
                if type == .keyDown { DispatchQueue.main.async { self.otherKeyPressed() } }
                return
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard !isRepeat else { return }
            switch type {
            case .keyDown: DispatchQueue.main.async { self.keyPressed() }
            case .keyUp: DispatchQueue.main.async { self.keyReleased() }
            default: break
            }
            return
        }

        guard let flag = hotkey.flag else { return }

        // An ordinary key pressed while we're waiting to arm means the modifier
        // was a prefix, not a trigger. This is the ⌥⌦ case.
        if type == .keyDown {
            DispatchQueue.main.async { self.otherKeyPressed() }
            return
        }

        // Modifier key: state is implied by the flag mask on .flagsChanged.
        guard type == .flagsChanged else { return }

        if let expected = hotkey.modifierKeyCode, keyCode != expected {
            // A *different* modifier moved. Same story as an ordinary key.
            DispatchQueue.main.async { self.otherKeyPressed() }
            return
        }

        let down = event.flags.contains(flag)
        // Anything else held at the moment our key goes down makes this a chord.
        let others = event.flags.intersection(Self.chordFlags).subtracting(flag)
        DispatchQueue.main.async {
            down ? self.keyPressed(chorded: !others.isEmpty) : self.keyReleased()
        }
    }

    // MARK: - Driving it without an event tap

    // The gesture logic is where the bugs live, and it can't be reached from a
    // test while real key events are the only way in. These are the very same
    // entry points the tap uses — no parallel implementation to drift.

    public func simulateKeyDown(chorded: Bool = false) { keyPressed(chorded: chorded) }
    public func simulateKeyUp() { keyReleased() }
    public func simulateOtherKey() { otherKeyPressed() }
    public func simulateEsc() { escPressed() }

    /// Forget the press in progress. Called when the controller refused to start
    /// a dictation — otherwise this side carries on believing it is recording or
    /// latched, and the next tap means "stop" here while it means "start" there.
    /// That disagreement is what made the key appear to do nothing.
    public func abandonPress() {
        let wasDown = keyIsDown
        resetState()
        // Keep the physical key state: if it is still held, its release must
        // not be read as the start of a new press.
        keyIsDown = wasDown
        pressDisqualified = wasDown
    }

    // MARK: - Main thread: all state lives here

    private func keyPressed(chorded: Bool = false) {
        guard !keyIsDown else { return }
        keyIsDown = true
        pressDisqualified = false

        // ⌘⌥, ⌃⌥, ⇧⌥ — a chord is never a dictation, and there is nothing to
        // wait for: we already know.
        if chorded {
            pressDisqualified = true
            lastTapEnded = 0
            return
        }

        // A tap while latched means "I'm done".
        if isLatched {
            isLatched = false
            isRecording = false
            emit(.finish)
            return
        }

        let delay = armDelay
        guard delay > 0 else {
            // No delay to wait out: start on the way down, and let the release
            // work out whether it was half a double-tap.
            if let timer = doubleTapTimer {
                timer.invalidate()
                doubleTapTimer = nil
                isLatched = true
                emit(.latch)
                return
            }
            beginRecording()
            return
        }

        // Second tap of a double-tap. Nothing was recorded for the first one, so
        // open and latch in one go — the pre-roll still covers what was said.
        if CFAbsoluteTimeGetCurrent() - lastTapEnded < doubleTapWindow {
            lastTapEnded = 0
            beginRecording()
            isLatched = true
            emit(.latch)
            return
        }

        armTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.armTimer = nil
            guard self.keyIsDown, !self.pressDisqualified, !self.isRecording else { return }
            self.beginRecording()
        }
    }

    private func keyReleased() {
        keyIsDown = false

        // Released before it armed: a tap. It records nothing on its own, but a
        // second one within the window latches.
        if let timer = armTimer {
            timer.invalidate()
            armTimer = nil
            lastTapEnded = pressDisqualified ? 0 : CFAbsoluteTimeGetCurrent()
            pressDisqualified = false
            return
        }

        if pressDisqualified {
            pressDisqualified = false
            return
        }

        guard isRecording, !isLatched else { return }

        // Surviving the arming delay is itself proof this was a deliberate hold.
        if armDelay > 0 {
            isRecording = false
            emit(.finish)
            return
        }

        let held = CFAbsoluteTimeGetCurrent() - pressStarted
        if held >= holdThreshold {
            isRecording = false
            emit(.finish)
            return
        }

        // Short press: might be half of a double-tap. Hold the decision briefly.
        doubleTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.doubleTapTimer = nil
            guard self.isRecording else { return }
            self.isRecording = false
            self.emit(.finish)
        }
    }

    private func beginRecording() {
        pressStarted = CFAbsoluteTimeGetCurrent()
        isRecording = true
        emit(.begin)
    }

    /// Any key that isn't ours, pressed while a press is still proving itself.
    /// Deliberately silent: chords are the common case, and logging every ⌥⌦
    /// would bury the lines that matter.
    private func otherKeyPressed() {
        guard armTimer != nil else { return }
        armTimer?.invalidate()
        armTimer = nil
        pressDisqualified = true
        lastTapEnded = 0
    }

    private func returnPressed() {
        guard isLatched else { return }
        isLatched = false
        isRecording = false
        emit(.finish)
    }

    /// For drawing the popup in a test: claim interception is available without
    /// creating a real tap, which would intercept keys on the machine running it.
    public func previewInterceptAvailable() { canIntercept = true }

    /// Test entry for Return, through the same decision the tap makes.
    public func simulateReturn() -> Bool {
        swallowLock.lock()
        let swallow = swallowReturn
        if swallow { swallowReturn = false }
        swallowLock.unlock()
        if swallow { returnPressed() }
        return swallow
    }

    private func escPressed() {
        guard isRecording else { return }
        resetState()
        emit(.cancel)
    }

    private func resetState() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        armTimer?.invalidate()
        armTimer = nil
        pressDisqualified = false
        lastTapEnded = 0
        keyIsDown = false
        isRecording = false
        isLatched = false
    }

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
    }
}
