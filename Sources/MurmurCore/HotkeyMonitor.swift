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

    /// A press at least this long is an intentional hold, not half a double-tap.
    private let holdThreshold: TimeInterval = 0.25
    /// How long to wait for a second tap before treating the first as a real (tiny) dictation.
    private let doubleTapWindow: TimeInterval = 0.3

    private static let escKeyCode: Int64 = 53

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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.classify(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            // Almost always means Input Monitoring hasn't been granted.
            return false
        }

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
            guard keyCode == Int64(target) else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard !isRepeat else { return }
            switch type {
            case .keyDown: DispatchQueue.main.async { self.keyPressed() }
            case .keyUp: DispatchQueue.main.async { self.keyReleased() }
            default: break
            }
            return
        }

        // Modifier key: state is implied by the flag mask on .flagsChanged.
        guard type == .flagsChanged, let flag = hotkey.flag else { return }
        if let expected = hotkey.modifierKeyCode, keyCode != expected { return }
        let down = event.flags.contains(flag)
        DispatchQueue.main.async { down ? self.keyPressed() : self.keyReleased() }
    }

    // MARK: - Main thread: all state lives here

    private func keyPressed() {
        guard !keyIsDown else { return }
        keyIsDown = true

        // A tap while latched means "I'm done".
        if isLatched {
            isLatched = false
            isRecording = false
            emit(.finish)
            return
        }

        // A tap inside the double-tap window promotes the pending press to latch mode.
        if let timer = doubleTapTimer {
            timer.invalidate()
            doubleTapTimer = nil
            isLatched = true
            emit(.latch)
            return
        }

        pressStarted = CFAbsoluteTimeGetCurrent()
        isRecording = true
        emit(.begin)
    }

    private func keyReleased() {
        keyIsDown = false
        guard isRecording, !isLatched else { return }

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

    private func escPressed() {
        guard isRecording else { return }
        resetState()
        emit(.cancel)
    }

    private func resetState() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        keyIsDown = false
        isRecording = false
        isLatched = false
    }

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
    }
}
