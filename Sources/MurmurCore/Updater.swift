import AppKit
import Foundation

public enum UpdateInstallError: LocalizedError {
    case noDownload
    case download(String)
    case rejected(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .noDownload: "That release has no download attached"
        case .download(let detail): "Download failed: \(detail)"
        // Worth being blunt. This is the one error that might mean something
        // is actually wrong rather than merely broken.
        case .rejected(let why): "Refused to install: \(why)"
        case .install(let detail): "Install failed: \(detail)"
        }
    }
}

/// Downloads a release and replaces the installed app with it.
///
/// An updater is the most dangerous code in an app: it is the one component
/// whose job is to fetch something from the internet and run it, and in this
/// case the thing it replaces already holds Accessibility, Input Monitoring and
/// microphone permission. Those permissions survive the swap precisely *because*
/// the signature matches — so the signature check is not a formality, it is the
/// whole security model.
///
/// Nothing from the download is executed, opened, or moved into place until all
/// of the following hold:
///
///   1. The URL is https on a GitHub host (checked before the request).
///   2. `codesign --verify --deep --strict` passes on the downloaded bundle.
///   3. Its Team ID is exactly ours. A valid Developer ID signature belonging to
///      *somebody else* is not good enough and is the obvious attack.
///   4. Gatekeeper reports it as notarised — Apple has seen this exact build.
///   5. Its version is strictly newer than the running one, so a downgrade
///      cannot be used to reintroduce a fixed bug.
///
/// Together these mean a hostile update would require both this Developer ID's
/// private key and Apple's notary service. That is the same bar macOS applies to
/// launching the app at all, which is the strongest guarantee available without
/// inventing a second signing scheme.
public actor Updater {
    /// Ours. Checked literally — see the note above about somebody else's
    /// perfectly valid signature.
    public static let expectedTeamID = "7CMPG6N65Y"

    public static let installedPath = "/Applications/Murmur.app"

    private let session: URLSession
    private let currentVersion: SemanticVersion

    public init(session: URLSession = .shared, currentVersion: String? = nil) {
        self.session = session
        let raw = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        self.currentVersion = SemanticVersion(raw) ?? SemanticVersion("0.0.0")!
    }

    /// Downloads, verifies and stages an update. Returns the staged bundle,
    /// ready for `relaunch(replacing:)`.
    public func stage(
        _ update: AvailableUpdate,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let remote = update.downloadURL else { throw UpdateInstallError.noDownload }
        guard UpdateChecker.trusted(remote) != nil else {
            throw UpdateInstallError.rejected("download URL is not a GitHub https link")
        }

        let work = try makeWorkDirectory()
        let dmg = work.appendingPathComponent("update.dmg")

        Log.echo("update: downloading \(update.version)")
        onProgress(0)
        let (tempFile, response) = try await session.download(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateInstallError.download("HTTP \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: tempFile, to: dmg)
        onProgress(0.6)

        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                      "-mountpoint", mount.path]).ok else {
            throw UpdateInstallError.install("could not open the disk image")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let app = mount.appendingPathComponent("Murmur.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateInstallError.install("no Murmur.app inside the disk image")
        }

        try verifyForInstall(app)
        onProgress(0.85)

        // Copy off the read-only image before it is detached.
        let staged = work.appendingPathComponent("Murmur.app")
        guard run("/usr/bin/ditto", [app.path, staged.path]).ok else {
            throw UpdateInstallError.install("could not stage the new app")
        }
        onProgress(1)
        Log.echo("update: staged and verified \(update.version)")
        return staged
    }

    // MARK: - Verification

    /// Public so it can be tested against real bundles rather than trusted. The
    /// interesting cases are a tampered copy of our own app and a perfectly
    /// valid Apple-signed app that simply isn't ours.
    public func verifyForInstall(_ app: URL) throws {
        let deep = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard deep.ok else {
            throw UpdateInstallError.rejected("the signature does not verify")
        }

        let details = run("/usr/bin/codesign", ["-dvv", app.path])
        guard let team = details.output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })?
            .dropFirst("TeamIdentifier=".count),
            String(team) == Self.expectedTeamID
        else {
            throw UpdateInstallError.rejected("it is signed by a different developer")
        }

        // Gatekeeper's own verdict. `accepted` alone is not enough: an ad-hoc or
        // merely Developer ID signed build can be accepted under other policies,
        // and only a notarised one has been seen by Apple.
        let gate = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path])
        guard gate.ok, gate.output.contains("source=Notarized Developer ID") else {
            throw UpdateInstallError.rejected("Apple has not notarised this build")
        }

        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let raw = plist["CFBundleShortVersionString"] as? String,
              let incoming = SemanticVersion(raw) else {
            throw UpdateInstallError.rejected("the bundle does not state a version")
        }
        guard incoming > currentVersion else {
            throw UpdateInstallError.rejected("\(incoming) is not newer than \(currentVersion)")
        }

        Log.echo("update: verified \(incoming) · team \(Self.expectedTeamID) · notarised")
    }

    // MARK: - Swap and relaunch

    /// Hands the swap to a detached script and quits, because an app cannot
    /// reliably replace itself while it is running — resources loaded after the
    /// bundle changed underneath it come from the new copy.
    @MainActor
    public static func relaunch(replacing destination: String = installedPath, with staged: URL) throws {
        let script = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        // Every path here is one we created; nothing from the network reaches
        // this string. Quoted regardless.
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /usr/bin/ditto "\(staged.path)" "\(destination)"
        /usr/bin/open -a "\(destination)"
        /bin/rm -rf "\(staged.deletingLastPathComponent().path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        try task.run()

        Log.echo("update: handing over to the installer and quitting")
        NSApp.terminate(nil)
    }

    // MARK: - Plumbing

    private func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    @discardableResult
    private nonisolated func run(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
