import Foundation

/// Models offered for the cleanup pass, with the tradeoff spelled out — the
/// picker should let you choose on facts, not vibes.
public enum CleanupModel: String, CaseIterable, Codable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"
    case opus5 = "claude-opus-5"

    public static let `default`: CleanupModel = .sonnet5

    public var displayName: String {
        switch self {
        case .sonnet5: "Claude Sonnet 5"
        case .haiku45: "Claude Haiku 4.5"
        case .opus5: "Claude Opus 5"
        }
    }

    public var tradeoff: String {
        switch self {
        case .sonnet5:
            "Best balance. Handles self-corrections and context well. ~$4/mo at 2k words a day."
        case .haiku45:
            "Fastest and cheapest (~$1.50/mo). Looser on hard self-corrections."
        case .opus5:
            "Most accurate, slowest, priciest. Overkill for dictation — here if you want it."
        }
    }

    /// Cost per million tokens, for the usage log. Snapshotted onto each row so
    /// past spend doesn't get rewritten when prices change (SPEC.md §7).
    public var pricing: (input: Double, output: Double) {
        switch self {
        case .sonnet5: (3.00, 15.00)
        case .haiku45: (1.00, 5.00)
        case .opus5: (5.00, 25.00)
        }
    }

    /// Haiku 4.5 predates adaptive thinking; the newer models default it *on*,
    /// which we don't want on a latency-critical path.
    var needsThinkingDisabled: Bool {
        switch self {
        case .haiku45: false
        case .sonnet5, .opus5: true
        }
    }

    /// `output_config.effort` is rejected outright by Haiku 4.5 — sending it
    /// returns a 400 and the whole cleanup silently falls back to raw text.
    var supportsEffort: Bool {
        switch self {
        case .haiku45: false
        case .sonnet5, .opus5: true
        }
    }
}

public enum CleanupPreference {
    private static let modelKey = "com.torimi.murmur.cleanup.model"
    private static let enabledKey = "com.torimi.murmur.cleanup.enabled"

    public static var model: CleanupModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modelKey),
                  let model = CleanupModel(rawValue: raw) else { return .default }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
    }

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
