import AppKit
import ApplicationServices

/// Whether there is somewhere for text to land.
///
/// Dictating with no text field focused ends in nothing: the transcript is
/// pasted into a window that ignores it. Better not to open the recorder at all.
///
/// The bias is deliberately one-sided. Accessibility is inconsistent across
/// apps — Electron, web views and custom text engines all describe themselves
/// differently, and some describe themselves not at all — so a wrong "no" is far
/// more damaging than a wrong "yes": it makes the app look broken while the user
/// is staring at a perfectly good text field. Only an explicit, unambiguous
/// non-text role counts as a refusal. Everything else, including silence from
/// the app, is treated as maybe.
public enum EditableFocus: Equatable, Sendable {
    /// A text field, text area or anything else that takes typing.
    case editable
    /// Something that unambiguously cannot: a button, an image, a bare window.
    case notEditable(role: String)
    /// Accessibility is unavailable, or the app didn't say enough to judge.
    case unknown

    /// Only an explicit refusal blocks. `unknown` always proceeds.
    public var allowsDictation: Bool { !isRefusal }
    public var isRefusal: Bool { if case .notEditable = self { return true }; return false }
}

public struct FocusReading: Sendable {
    public let focus: EditableFocus
    /// What the element said about itself, for tuning the lists against reality.
    public let description: String
}

public enum FocusProbe {
    /// Accessibility calls are synchronous IPC into another app, and the default
    /// timeout is six seconds. On the path that opens the recorder that is not a
    /// budget, it's a hang — so cap it hard. A probe that times out reports
    /// `unknown`, which proceeds, which is the right answer anyway.
    private static let messagingTimeout: Float = 0.15
    /// Roles that take text. Chromium maps `contenteditable` onto AXTextArea, so
    /// this covers most web and Electron editors too.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Roles that unambiguously take no text.
    ///
    /// Tables, rows, cells and web areas are deliberately absent: a selected
    /// spreadsheet cell does accept a paste, and a web area is as likely to be a
    /// rich text editor as an article. When in doubt this list stays out of the
    /// way — see the note on the enum.
    private static let refusingRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuItemRole, kAXMenuBarItemRole, kAXMenuButtonRole,
        kAXImageRole, kAXStaticTextRole, kAXSliderRole, "AXLink",
        kAXTabGroupRole, kAXToolbarRole, kAXScrollBarRole,
        kAXWindowRole, kAXSheetRole, kAXDisclosureTriangleRole,
    ]

    public static func current() -> EditableFocus { probe().focus }

    /// Verdict and diagnostics from a single pass. They used to be two calls,
    /// which meant paying for every accessibility round trip twice on the path
    /// that opens the recorder.
    public static func probe() -> FocusReading {
        guard AXIsProcessTrusted() else {
            return FocusReading(focus: .unknown, description: "accessibility not granted")
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else {
            // Plenty of healthy apps report nothing here. Not evidence of absence.
            return FocusReading(focus: .unknown, description: "no focused element")
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = string(focused, kAXRoleAttribute) ?? ""
        let subrole = string(focused, kAXSubroleAttribute) ?? "-"
        let range = hasAttribute(focused, kAXSelectedTextRangeAttribute)
        let settable = isSettable(focused, kAXValueAttribute)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let described = "app=\(app) role=\(role) subrole=\(subrole) selectedTextRange=\(range) valueSettable=\(settable)"

        let verdict: EditableFocus
        if editableRoles.contains(role) {
            verdict = .editable
        } else if range || settable {
            // Role names are not exhaustive — a custom text engine can call
            // itself anything. Supporting a selected text range is the behaviour
            // that actually matters, so trust that over the label.
            verdict = .editable
        } else if refusingRoles.contains(role) {
            verdict = .notEditable(role: role)
        } else {
            verdict = .unknown
        }
        return FocusReading(focus: verdict, description: described)
    }

    // MARK: - AX plumbing

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(attribute)
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }
}

public enum FocusGatePreference {
    private static let key = "com.torimi.murmur.requireTextField"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
