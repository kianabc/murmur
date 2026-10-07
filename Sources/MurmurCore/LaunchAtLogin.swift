import Foundation
import ServiceManagement

/// Whether Murmur opens when you log in.
///
/// A dictation app that has to be remembered and started by hand every morning
/// is one that quietly stops being used. So it is on by default — registered
/// once, on the first launch that has an opinion — and after that the user's
/// choice wins, whether made here or in System Settings → General → Login Items.
///
/// The truth is always read back from the system rather than kept in a flag of
/// our own, because the user can switch it off in System Settings without
/// Murmur ever being told.
public enum LaunchAtLogin {
    private static let decidedKey = "com.torimi.murmur.launchAtLogin.decided"

    public enum State: Equatable, Sendable {
        case on
        case off
        /// Registered, but macOS wants the user to allow it in System Settings.
        case needsApproval
        /// This copy can't be a login item — see `isInstalledCopy`.
        case unavailable
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered: isInstalledCopy() ? .off : .unavailable
        case .notFound: .unavailable
        @unknown default: .off
        }
    }

    /// Turns it on or off at the user's request. Recorded as decided either way,
    /// so the default is never applied over a choice they made.
    public static func set(_ on: Bool) throws {
        UserDefaults.standard.set(true, forKey: decidedKey)
        if on {
            try SMAppService.mainApp.register()
            Log.echo("launch at login: on")
        } else {
            try SMAppService.mainApp.unregister()
            Log.echo("launch at login: off")
        }
    }

    /// The default, applied once. Call at launch.
    public static func applyDefaultIfUndecided() {
        guard shouldApplyDefault(
            decided: UserDefaults.standard.bool(forKey: decidedKey),
            bundlePath: Bundle.main.bundlePath
        ) else { return }
        UserDefaults.standard.set(true, forKey: decidedKey)
        do {
            try SMAppService.mainApp.register()
            Log.echo("launch at login: on by default")
        } catch {
            Log.echo("launch at login: could not register — \(error.localizedDescription)")
        }
    }

    /// Pure, so it can be tested without touching the real login items.
    ///
    /// Only a copy that lives in an Applications folder is registered. One
    /// running from the disk image, from Downloads, or from a build folder would
    /// leave a login item pointing at somewhere that won't exist next week —
    /// and macOS runs apps opened from Downloads from a randomised read-only
    /// copy, which is worse still.
    public static func shouldApplyDefault(decided: Bool, bundlePath: String) -> Bool {
        !decided && isInstalledCopy(bundlePath)
    }

    public static func isInstalledCopy(_ path: String = Bundle.main.bundlePath) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }
}
