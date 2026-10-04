import Foundation

/// Step-by-step instructions for getting a key from each provider, written for
/// someone who has never seen an API console. Shown in Settings beside the
/// paste field and in the first-run nudge, so nobody has to be walked through
/// it in person.
public extension CleanupProvider {
    var keySteps: [String] {
        switch self {
        case .anthropic: [
            "Click **Get an Anthropic API key** above. Sign in or create an account — you'll need to add a payment method, and a few dollars lasts months.",
            "On the **API Keys** page, click **Create Key**. Any name is fine.",
            "Copy the key that appears. It starts with `sk-ant-` and is shown only once.",
            "Come back here and paste it into the field. Murmur checks it straight away.",
        ]
        case .openAI: [
            "Click **Get an OpenAI API key** above. Sign in or create an account, and add a little credit under **Billing** — a few dollars lasts months.",
            "On the **API keys** page, click **Create new secret key**.",
            "Copy the key that appears. It starts with `sk-` and is shown only once.",
            "Come back here and paste it into the field. Murmur checks it straight away.",
        ]
        case .gemini: [
            "Click **Get a Google API key** above and sign in with any Google account.",
            "Click **Create API key** and pick or create a project. The free tier is enough for dictation.",
            "Copy the key that appears. It starts with `AIza`.",
            "Come back here and paste it into the field. Murmur checks it straight away.",
        ]
        }
    }

    /// One line on cost, for choosing between them.
    var costLine: String {
        "\(defaultModel.displayName) · \(defaultModel.monthlyEstimate) for heavy use"
    }
}

/// Decides when to suggest turning on cleanup.
///
/// Someone who installs Murmur and dictates a few times without an API key is
/// getting the raw transcript and may never learn the main feature exists. After
/// a couple of dictations it asks once, and again much later if they said "not
/// now" — but never again if they said so.
public enum CleanupNudge {
    private static let countKey = "com.torimi.murmur.nudge.dictationsWithoutKey"
    private static let dismissedKey = "com.torimi.murmur.nudge.dismissed"
    private static let snoozedUntilKey = "com.torimi.murmur.nudge.snoozedUntil"

    /// Ask after this many dictations that went out without cleanup — enough
    /// that the app has proved useful, not so many that the habit has set.
    public static let askAfter = 5
    /// "Not now" means this many more before asking again.
    public static let askAgainAfter = 25

    /// Call once per dictation that skipped cleanup for lack of a key. Returns
    /// true when it is time to ask.
    public static func noteDictationWithoutKey(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: dismissedKey) else { return false }
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        let threshold = defaults.integer(forKey: snoozedUntilKey)
        if threshold > 0 { return count >= threshold }
        return count == askAfter
    }

    public static func snooze(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: countKey) + askAgainAfter, forKey: snoozedUntilKey)
    }

    public static func dismissForever(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedKey)
    }

    public static func reset(defaults: UserDefaults = .standard) {
        for key in [countKey, dismissedKey, snoozedUntilKey] { defaults.removeObject(forKey: key) }
    }
}
