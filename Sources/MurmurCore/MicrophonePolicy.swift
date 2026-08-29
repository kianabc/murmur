import Foundation

/// When Murmur is allowed to hold the microphone open.
///
/// macOS shows an orange indicator for as long as any app has the microphone,
/// and keeping it open all day makes that indicator permanent. It is telling the
/// truth — the microphone really is open — so the honest fix is to stop holding
/// it, not to make the indicator quieter.
public enum MicrophonePolicy: String, CaseIterable, Codable, Sendable {
    /// Opened when you start dictating, closed the moment you stop. The
    /// indicator appears only while you are actually speaking to it.
    case onDemand
    /// Held open for the life of the app. Saves the ~100ms it takes to start,
    /// and keeps the rolling pre-roll that catches a word begun before the key
    /// was fully pressed.
    case alwaysOpen

    public static let `default`: MicrophonePolicy = .onDemand

    public var displayName: String {
        switch self {
        case .onDemand: "Only while dictating"
        case .alwaysOpen: "Always (slightly faster)"
        }
    }

    public var detail: String {
        switch self {
        case .onDemand:
            "macOS shows its orange microphone indicator only while you're dictating. Starting the microphone adds a moment, and a word begun before the key is fully pressed may be clipped."
        case .alwaysOpen:
            "The microphone stays open, so dictation starts instantly and catches words begun as you reach for the key. macOS will show its orange microphone indicator at all times."
        }
    }
}

public enum MicrophonePreference {
    private static let key = "com.torimi.murmur.microphonePolicy"

    public static var current: MicrophonePolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let policy = MicrophonePolicy(rawValue: raw) else { return .default }
            return policy
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
