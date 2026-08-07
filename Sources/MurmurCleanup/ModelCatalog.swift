import Foundation

public enum CleanupProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI (ChatGPT)"
        }
    }

    /// Separate Keychain entry per provider, so switching back and forth doesn't
    /// make you re-paste a key you already gave.
    public var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openAI: "openai-api-key"
        }
    }

    public var keyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    public var keyPrefixHint: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        }
    }

    /// Cheapest first. The picker is ordered so the sensible default is at the
    /// top and cost rises as you go down.
    public var models: [CleanupModelSpec] { CleanupModelSpec.catalog.filter { $0.provider == self } }

    public var defaultModel: CleanupModelSpec { models[0] }
}

/// One selectable model.
///
/// Prices are dollars per million tokens, taken from each vendor's own pricing
/// page. They move, and a stale figure here only affects *future* estimates —
/// every logged request snapshots the price in force at the time, so history
/// stays correct even when this table drifts.
public struct CleanupModelSpec: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: CleanupProvider
    public let displayName: String
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double
    public let blurb: String

    /// The live price if one has been fetched, otherwise the compiled default.
    public var pricing: (input: Double, output: Double) {
        PriceTable.overrides()[id] ?? (inputPricePerMTok, outputPricePerMTok)
    }

    /// A rough monthly figure at ~2,000 words dictated a day, which is a heavy
    /// user. Concrete beats "cheap" and "expensive".
    public var monthlyEstimate: String {
        // ~13 requests per 1,000 words; ~700 tokens in, ~45 out per request.
        let requestsPerMonth = 2.0 * 13 * 30
        let live = pricing
        let cost = requestsPerMonth
            * (700 / 1_000_000 * live.input + 45 / 1_000_000 * live.output)
        return cost < 1
            ? String(format: "~%.0f¢/mo", cost * 100)
            : String(format: "~$%.2f/mo", cost)
    }

    // Ordered cheapest → most capable within each provider.
    public static let catalog: [CleanupModelSpec] = [
        // MARK: Anthropic
        .init(id: "claude-haiku-4-5", provider: .anthropic, displayName: "Claude Haiku 4.5",
              inputPricePerMTok: 1.00, outputPricePerMTok: 5.00,
              blurb: "Fastest. Handles ordinary cleanup well."),
        .init(id: "claude-sonnet-5", provider: .anthropic, displayName: "Claude Sonnet 5",
              inputPricePerMTok: 3.00, outputPricePerMTok: 15.00,
              blurb: "Better at hard self-corrections and context."),
        .init(id: "claude-opus-5", provider: .anthropic, displayName: "Claude Opus 5",
              inputPricePerMTok: 5.00, outputPricePerMTok: 25.00,
              blurb: "Most capable. Overkill for dictation."),

        // MARK: OpenAI
        .init(id: "gpt-3.5-turbo", provider: .openAI, displayName: "GPT-3.5 Turbo",
              inputPricePerMTok: 0.50, outputPricePerMTok: 1.50,
              blurb: "Cheapest anywhere, but an older model — expect misses."),
        .init(id: "gpt-4o", provider: .openAI, displayName: "GPT-4o",
              inputPricePerMTok: 2.50, outputPricePerMTok: 10.00,
              blurb: "Solid all-rounder."),
        .init(id: "gpt-5.6-sol", provider: .openAI, displayName: "GPT-5.6 Sol",
              inputPricePerMTok: 5.00, outputPricePerMTok: 30.00,
              blurb: "OpenAI's most capable. Priciest output of any option."),

    ]

    public static func find(_ id: String) -> CleanupModelSpec? {
        catalog.first { $0.id == id }
    }
}

public enum CleanupPreference {
    private static let modelKey = "com.torimi.murmur.cleanup.modelID"
    private static let enabledKey = "com.torimi.murmur.cleanup.enabled"

    public static var model: CleanupModelSpec {
        get {
            guard let id = UserDefaults.standard.string(forKey: modelKey),
                  let found = CleanupModelSpec.find(id) else {
                return CleanupProvider.anthropic.defaultModel
            }
            return found
        }
        set { UserDefaults.standard.set(newValue.id, forKey: modelKey) }
    }

    public static var provider: CleanupProvider { model.provider }

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
