import Foundation
import MurmurCore

public extension Notification.Name {
    /// Posted when a key's status changes, so open windows can update.
    static let murmurKeyStatusChanged = Notification.Name("com.torimi.murmur.keyStatusChanged")
}

public enum KeyStatus: Equatable, Sendable {
    /// Stored but never exercised.
    case untested
    case valid(Date)
    /// The provider refused it — revoked, mistyped, or out of credit.
    case rejected(Date, reason: String)

    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
}

/// Remembers whether each provider has accepted its key.
///
/// A key that worked yesterday can be revoked today, and the failure would
/// otherwise be invisible: cleanup silently falls back to the raw transcript and
/// the user just thinks the AI "stopped working". This makes it say so.
public enum KeyStatusStore {
    private static func key(_ provider: CleanupProvider) -> String {
        "com.torimi.murmur.keyStatus.\(provider.rawValue)"
    }

    public static func status(for provider: CleanupProvider) -> KeyStatus {
        guard let raw = UserDefaults.standard.dictionary(forKey: key(provider)),
              let state = raw["state"] as? String,
              let when = raw["at"] as? Date else { return .untested }
        switch state {
        case "valid": return .valid(when)
        case "rejected": return .rejected(when, reason: raw["reason"] as? String ?? "Rejected")
        default: return .untested
        }
    }

    public static func markValid(_ provider: CleanupProvider) {
        guard status(for: provider) != .valid(Date.distantPast) else { return }
        UserDefaults.standard.set(
            ["state": "valid", "at": Date()], forKey: key(provider)
        )
        notify()
    }

    public static func markRejected(_ provider: CleanupProvider, reason: String) {
        Log.echo("key: \(provider.rawValue) REJECTED — \(reason)")
        UserDefaults.standard.set(
            ["state": "rejected", "at": Date(), "reason": reason], forKey: key(provider)
        )
        notify()
    }

    /// Called when the key itself changes — the old verdict no longer applies.
    public static func reset(_ provider: CleanupProvider) {
        UserDefaults.standard.removeObject(forKey: key(provider))
        notify()
    }

    private static func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .murmurKeyStatusChanged, object: nil)
        }
    }
}

public struct KeyCheck: Sendable {
    public let isValid: Bool
    public let message: String
}

public extension CleanupService {
    /// Asks the provider whether the key works, without generating any tokens.
    ///
    /// Both providers expose a model-listing endpoint that authenticates but
    /// costs nothing, which is the cheapest honest way to answer the question.
    static func testKey(
        for provider: CleanupProvider,
        session: URLSession = .shared
    ) async -> KeyCheck {
        guard let key = KeyStore.key(for: provider), !key.isEmpty else {
            return KeyCheck(isValid: false, message: "No key set")
        }

        var request = URLRequest(url: provider.modelsURL)
        request.timeoutInterval = 15
        for (field, value) in provider.authHeaders(key: key) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return KeyCheck(isValid: false, message: "No response")
            }
            switch http.statusCode {
            case 200:
                KeyStatusStore.markValid(provider)
                return KeyCheck(isValid: true, message: "Key works")
            case let code where CleanupProvider.isKeyRejection(
                status: code, body: String(data: data, encoding: .utf8) ?? ""
            ):
                let reason = Self.reason(from: data) ?? "Key was rejected"
                KeyStatusStore.markRejected(provider, reason: reason)
                return KeyCheck(isValid: false, message: reason)
            case 429:
                // Rate-limited is not the same as invalid — saying otherwise
                // would send someone hunting for a key problem they don't have.
                return KeyCheck(isValid: true, message: "Rate limited, but the key is accepted")
            default:
                return KeyCheck(isValid: false, message: "Provider returned \(http.statusCode)")
            }
        } catch {
            // Offline is not a key problem either.
            return KeyCheck(isValid: false, message: "Couldn't reach \(provider.displayName)")
        }
    }

    /// Pulls a human-readable reason out of a provider error body. Both wrap it
    /// under "error", though not identically.
    static func reason(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        if let message = error["message"] as? String, !message.isEmpty {
            return String(message.prefix(140))
        }
        return error["type"] as? String
    }
}

extension CleanupProvider {
    /// Whether an HTTP failure means "the key is bad" rather than anything
    /// else. Anthropic and OpenAI say 401 or 403. Google says **400** with
    /// "API key not valid" in the body — the same status it uses for a
    /// malformed request, so the body has to be consulted.
    public static func isKeyRejection(status: Int, body: String) -> Bool {
        if status == 401 || status == 403 { return true }
        if status == 400 {
            let lowered = body.lowercased()
            return lowered.contains("api key not valid") || lowered.contains("api_key_invalid")
        }
        return false
    }

    /// A cheap authenticated endpoint used only to check the key.
    var modelsURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models")!
        case .openAI: URL(string: "https://api.openai.com/v1/models")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        }
    }

    func authHeaders(key: String) -> [String: String] {
        switch self {
        case .anthropic: ["x-api-key": key, "anthropic-version": "2023-06-01"]
        case .openAI: ["Authorization": "Bearer \(key)"]
        case .gemini: ["x-goog-api-key": key]
        }
    }
}
