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

    /// Decides from what the focused element says about itself.
    ///
    /// Written against what real apps actually reported, which was not what the
    /// first version assumed:
    ///
    ///   Claude, WhatsApp  AXTextArea   settable       takes text
    ///   Ghostty           AXTextArea   NOT settable   takes text
    ///   Google Chrome     AXTextField  settable       takes text
    ///   Claude            AXGroup      NOT settable   takes nothing
    ///
    /// Two signals had to be thrown out. `selectedTextRange` was true in every
    /// single reading including the failing one, so it distinguishes nothing —
    /// containers advertise it happily. `valueSettable` cannot stand alone
    /// either, because a terminal reports false and pastes perfectly well.
    ///
    /// So the role decides, and a settable value is kept only as an escape hatch
    /// for a custom text engine calling itself something non-standard. An
    /// earlier version had this backwards: it consulted the role first and then
    /// fell back to the useless signal, which is how a focused AXGroup was
    /// treated as a text field and a dictation vanished into it in silence.
    public static func classify(role: String, valueSettable: Bool) -> EditableFocus {
        if editableRoles.contains(role) { return .editable }
        if valueSettable { return .editable }
        return .notEditable(role: role.isEmpty ? "no role" : role)
    }

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
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard status == .success, let focused = focusedRef as! AXUIElement? else {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            // Two very different failures arrive here and must not be confused.
            //
            // `.noValue` is the system answering: nothing has keyboard focus.
            // That is a real "nowhere to type", and the text goes to the
            // clipboard with a message.
            //
            // Anything else — a timeout above all — is the app failing to
            // answer in time. That says nothing about where the cursor is, and
            // treating a busy app as an empty one would divert a perfectly good
            // paste to the clipboard. Silence is `unknown`, and unknown pastes.
            if status == .noValue {
                return FocusReading(
                    focus: .notEditable(role: "nothing focused"),
                    description: "app=\(app) nothing focused"
                )
            }
            return FocusReading(
                focus: .unknown,
                description: "app=\(app) no answer (AXError \(status.rawValue))"
            )
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = string(focused, kAXRoleAttribute) ?? ""
        let subrole = string(focused, kAXSubroleAttribute) ?? "-"
        let range = hasAttribute(focused, kAXSelectedTextRangeAttribute)
        let settable = isSettable(focused, kAXValueAttribute)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let described = "app=\(app) role=\(role) subrole=\(subrole) selectedTextRange=\(range) valueSettable=\(settable)"

        return FocusReading(
            focus: classify(role: role, valueSettable: settable),
            description: described
        )
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

/// Refusing to start when there's nowhere to type. Off by default: it throws
/// away the dictation, and keeping the words on the clipboard — which is what
/// happens now when the paste has nowhere to go — is better in every case where
/// the user has already spoken.
public enum FocusGatePreference {
    private static let key = "com.torimi.murmur.requireTextField"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
