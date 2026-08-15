import CoreGraphics
import Foundation

/// Which key starts dictation.
///
/// Two shapes of trigger, and they're detected differently:
///   • **Modifier keys** (fn, right ⌘/⌥) arrive as `.flagsChanged` with no
///     press/release events of their own — you infer state from the flag mask.
///   • **Regular keys** (F5) arrive as `.keyDown` / `.keyUp` with a keycode.
public enum Hotkey: String, CaseIterable, Codable, Sendable {
    case rightCommand
    case rightOption
    /// F5 is the microphone key on modern Macs and macOS claims it for its own
    /// Dictation even with Dictation switched off — it is offered, not default.
    case f5
    case f6
    case fn

    /// Right ⌘ has no system binding of its own, so it collides with nothing.
    public static let `default`: Hotkey = .rightCommand

    public var displayName: String {
        switch self {
        case .f5: "F5 (may trigger macOS Dictation)"
        case .f6: "F6"
        case .fn: "fn / 🌐"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        }
    }

    /// Keys that need `fn` held first when the keyboard is in media mode, so the
    /// UI can warn instead of the user thinking it's broken.
    public var isFunctionRow: Bool {
        self == .f5 || self == .f6
    }

    /// Modifier triggers are ambiguous by nature: ⌥ on its own means dictate,
    /// but ⌥ followed by ⌦ means delete a word. Only these need an arming delay
    /// to tell the two apart — a function key has nothing to disambiguate.
    public var isModifier: Bool { keyCode == nil }

    var keyCode: CGKeyCode? {
        switch self {
        case .f5: 96
        case .f6: 97
        case .fn, .rightCommand, .rightOption: nil
        }
    }

    /// The modifier flag to watch, for modifier-style triggers.
    var flag: CGEventFlags? {
        switch self {
        case .fn: .maskSecondaryFn
        case .rightCommand: .maskCommand
        case .rightOption: .maskAlternate
        case .f5, .f6: nil
        }
    }

    /// Modifier keys report a keycode on `.flagsChanged`; use it to tell left
    /// from right, which the flag mask alone can't do.
    var modifierKeyCode: Int64? {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .fn, .f5, .f6: nil
        }
    }
}

/// Persisted hotkey choice.
/// How long the dictation key must be held before recording starts.
///
/// This exists to tell a bare modifier from a chord: press ⌥ and we wait, and if
/// anything else arrives in the meantime it was ⌥⌦ or ⌘⌥ and we stay out of the
/// way. It costs nothing in captured words — `AudioCapture` keeps a rolling
/// pre-roll, so the audio from before the delay is still there.
public enum HoldDelayPreference {
    private static let key = "com.torimi.murmur.holdDelay"

    /// Offered in the UI. 0 is only sensible for a non-modifier key.
    public static let choices: [TimeInterval] = [0, 0.15, 0.2, 0.3]

    /// Long enough to catch a fast ⌥⌦, short enough not to feel sluggish.
    public static let defaultForModifiers: TimeInterval = 0.2

    public static func current(for hotkey: Hotkey) -> TimeInterval {
        guard hotkey.isModifier else { return 0 }
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double else {
            return defaultForModifiers
        }
        return stored
    }

    public static var stored: TimeInterval {
        get { UserDefaults.standard.object(forKey: key) as? Double ?? defaultForModifiers }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

public enum HotkeyPreference {
    private static let key = "com.torimi.murmur.hotkey"

    public static var current: Hotkey {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let hotkey = Hotkey(rawValue: raw) else { return .default }
            return hotkey
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
