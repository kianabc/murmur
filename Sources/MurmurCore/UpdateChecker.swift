import Foundation

/// A dotted version like `0.2.1`, comparable.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int

    /// Accepts `1.2.3` or `v1.2.3`, and tolerates a missing patch.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Drop any pre-release suffix — "1.2.0-beta.1" compares as 1.2.0.
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? text
        let parts = core.split(separator: ".").map { Int($0) ?? -1 }
        guard let first = parts.first, first >= 0 else { return nil }
        major = first
        minor = parts.count > 1 && parts[1] >= 0 ? parts[1] : 0
        patch = parts.count > 2 && parts[2] >= 0 ? parts[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

public struct AvailableUpdate: Sendable {
    public let version: SemanticVersion
    public let releaseNotes: String
    public let pageURL: URL
    /// Direct link to the .dmg, when the release has one.
    public let downloadURL: URL?
}

/// Checks GitHub Releases for a newer version.
///
/// Deliberately notify-only: it tells you an update exists and opens the release
/// page. Silent self-installation is Sparkle's job, and doing that safely needs a
/// signed app and an update-signing key — see SPEC.md §9. Until then, telling the
/// user beats pretending to be an auto-updater.
public actor UpdateChecker {
    public static let repository = "kianabc/murmur"

    private let session: URLSession
    private let currentVersion: SemanticVersion

    public init(session: URLSession = .shared, currentVersion: String? = nil) {
        self.session = session
        let raw = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        self.currentVersion = SemanticVersion(raw) ?? SemanticVersion("0.0.0")!
    }

    public var current: SemanticVersion { currentVersion }

    /// Returns an update only when the published release is strictly newer.
    public func check() async throws -> AvailableUpdate? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        // 404 just means nothing has been released yet — not an error worth
        // showing anyone.
        guard http.statusCode != 404 else { return nil }
        guard http.statusCode == 200 else {
            throw UpdateError.http(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let latest = SemanticVersion(tag) else { return nil }

        guard latest > currentVersion else { return nil }

        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(Self.repository)/releases/latest")!

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))

        return AvailableUpdate(version: latest, releaseNotes: notes, pageURL: page, downloadURL: dmg)
    }

    public enum UpdateError: LocalizedError {
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .http(let code): "Could not reach GitHub (HTTP \(code))"
            }
        }
    }
}

public enum UpdatePreference {
    private static let autoKey = "com.torimi.murmur.checkForUpdates"
    private static let lastKey = "com.torimi.murmur.lastUpdateCheck"

    public static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    public static var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: lastKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }

    /// Once a day is plenty for an app like this, and it keeps the launch path
    /// free of a network call on every start.
    public static var isDue: Bool {
        guard automatic else { return false }
        guard let last = lastChecked else { return true }
        return Date().timeIntervalSince(last) > 24 * 60 * 60
    }
}
