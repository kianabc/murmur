import Foundation

/// What happens to the text once it's ready.
public enum InsertionMode: String, CaseIterable, Codable, Sendable {
    /// Paste it into whatever app is frontmost. Needs Accessibility.
    case typeIntoApp
    /// Only put it on the clipboard and let the user paste it. Needs nothing.
    case clipboardOnly

    public static let `default`: InsertionMode = .typeIntoApp

    public var displayName: String {
        switch self {
        case .typeIntoApp: "Type into the current app"
        case .clipboardOnly: "Copy to clipboard only"
        }
    }

    public var detail: String {
        switch self {
        case .typeIntoApp:
            "Text appears at your cursor. Requires Accessibility permission."
        case .clipboardOnly:
            "Text is copied — press ⌘V yourself. Requires no extra permissions."
        }
    }

    public var requiresAccessibility: Bool { self == .typeIntoApp }
}

public enum InsertionPreference {
    private static let key = "com.torimi.murmur.insertion"

    public static var current: InsertionMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let mode = InsertionMode(rawValue: raw) else { return .default }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
