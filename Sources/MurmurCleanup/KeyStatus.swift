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
            case 401, 403:
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
    /// A cheap authenticated endpoint used only to check the key.
    var modelsURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models")!
        case .openAI: URL(string: "https://api.openai.com/v1/models")!
        }
    }

    func authHeaders(key: String) -> [String: String] {
        switch self {
        case .anthropic: ["x-api-key": key, "anthropic-version": "2023-06-01"]
        case .openAI: ["Authorization": "Bearer \(key)"]
        }
    }
}
