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
        // The list, not `/latest`: someone three versions behind should read
        // what all three did, not only the newest.
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=20")!
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

        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let newer: [(version: SemanticVersion, json: [String: Any])] = list.compactMap { json in
            guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
                  let tag = json["tag_name"] as? String,
                  let version = SemanticVersion(tag), version > currentVersion else { return nil }
            return (version, json)
        }
        .sorted { $0.version > $1.version }

        guard let latest = newer.first else { return nil }
        let json = latest.json

        let notes = Self.combinedNotes(newer.map { ($0.version, $0.json["body"] as? String ?? "") })

        // Both URLs below come from a network response and are handed to
        // NSWorkspace to open. Validate scheme and host rather than trusting
        // them — a `file:` or `javascript:` URL in that position would be
        // opened without question.
        let page = (json["html_url"] as? String)
            .flatMap(URL.init(string:))
            .flatMap(Self.trusted)
            ?? URL(string: "https://github.com/\(Self.repository)/releases/latest")!

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
            .flatMap(Self.trusted)

        return AvailableUpdate(version: latest.version, releaseNotes: notes, pageURL: page, downloadURL: dmg)
    }

    /// One block of notes covering every version being skipped over, newest
    /// first, each under its own bold version line. Markdown headings and rules
    /// in the bodies are flattened, because the alert that shows this renders
    /// inline markdown only.
    public static func combinedNotes(_ releases: [(SemanticVersion, String)]) -> String {
        releases.map { version, body in
            let cleaned = body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") {
                        let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                        return text.isEmpty ? "" : "**\(text)**"
                    }
                    if trimmed == "---" { return "" }
                    return String(line)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "**Murmur \(version)**\n\(cleaned)"
        }
        .joined(separator: "\n\n")
    }

    /// Only https URLs on GitHub's own hosts are ever opened.
    public static func trusted(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let allowed = ["github.com", "www.github.com", "objects.githubusercontent.com",
                       "release-assets.githubusercontent.com"]
        return allowed.contains(host) ? url : nil
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

    /// Once a day is plenty for an app like this. Asked at launch and then every
    /// hour while running — asking only at launch meant a copy left open for a
    /// week never checked at all.
    public static var isDue: Bool {
        guard automatic else { return false }
        guard let last = lastChecked else { return true }
        return Date().timeIntervalSince(last) > 24 * 60 * 60
    }
}
