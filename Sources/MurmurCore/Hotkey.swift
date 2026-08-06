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
