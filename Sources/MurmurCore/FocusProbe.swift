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

public enum FocusProbe {
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

    public static func current() -> EditableFocus {
        guard AXIsProcessTrusted() else { return .unknown }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else {
            // Plenty of healthy apps report nothing here. Not evidence of absence.
            return .unknown
        }

        let role = string(focused, kAXRoleAttribute) ?? ""

        if editableRoles.contains(role) { return .editable }

        // Role names are not exhaustive — a custom text engine can call itself
        // anything. Supporting a selected text range is the behaviour that
        // actually matters, so trust that over the label.
        if hasAttribute(focused, kAXSelectedTextRangeAttribute) { return .editable }
        if isSettable(focused, kAXValueAttribute) { return .editable }

        if refusingRoles.contains(role) { return .notEditable(role: role) }

        return .unknown
    }

    /// What the focused element actually says about itself. Diagnostics only —
    /// the deny-list is only tunable against real apps, and guessing at role
    /// names from documentation is how it ends up not firing where it matters.
    public static func describeCurrent() -> String {
        guard AXIsProcessTrusted() else { return "accessibility not granted" }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else {
            return "no focused element"
        }
        let role = string(focused, kAXRoleAttribute) ?? "(no role)"
        let subrole = string(focused, kAXSubroleAttribute) ?? "-"
        let range = hasAttribute(focused, kAXSelectedTextRangeAttribute)
        let settable = isSettable(focused, kAXValueAttribute)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        return "app=\(app) role=\(role) subrole=\(subrole) selectedTextRange=\(range) valueSettable=\(settable)"
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
