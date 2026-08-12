import Foundation

/// Which build this is. Worth stating out loud: it's easy to end up with several
/// copies of a menu-bar app on one Mac — an installed one, a mounted disk image,
/// a local build — and nothing on screen says which one you're looking at.
public enum AppVersion {
    public static var current: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
