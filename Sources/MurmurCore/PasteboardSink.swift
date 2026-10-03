import AppKit
import ApplicationServices
import CoreGraphics

public enum InsertError: LocalizedError {
    case secureInputActive
    case accessibilityDenied

    public var errorDescription: String? {
        switch self {
        case .secureInputActive: "A secure input field is focused"
        case .accessibilityDenied: "Accessibility permission is required to type"
        }
    }
}

/// Inserts text by saving the pasteboard, writing ours, synthesizing ⌘V, and
/// restoring. Ugly, universal, and what every shipping tool in this space does —
/// AX direct insertion silently misbehaves in Electron, Chrome fields, and
/// terminals, which is most of where people actually type. See SPEC.md §3.5.
public final class PasteboardSink: TextSink {
    /// How long to wait for the target app to consume our paste before restoring.
    private let restoreDelay: TimeInterval = 0.15
    private static let vKeyCode: CGKeyCode = 9

    public init() {}

    /// Set when we could only reach the clipboard, so the UI can say "copied —
    /// press ⌘V" instead of pretending it typed.
    public private(set) var lastInsertWasClipboardOnly = false

    /// Called on the main thread when a paste demonstrably didn't land and the
    /// text has been left on the clipboard instead.
    public var onPasteFallback: ((String) -> Void)?

    /// A cheap fingerprint of the focused text field: how much text it holds and
    /// where the caret sits. Both move when a paste lands, and comparing two
    /// numbers avoids copying a whole document out of the app twice.
    private struct FieldState: Equatable {
        let characters: Int
        let caret: Int
    }

    private static let axTimeout: Float = 0.15

    /// Whether to put a space in front of what we're about to insert.
    ///
    /// Two dictations in a row used to run straight together — "…back to
    /// back.You can see it here." — because each insertion knows nothing about
    /// what came before it. Pure, so the judgement can be tested without a text
    /// field; `precedingCharacter()` supplies the input.
    public static func needsLeadingSpace(after previous: Character?, inserting text: String) -> Bool {
        guard let first = text.first, !first.isWhitespace else { return false }
        // Nothing before us, or we couldn't find out: add nothing. A missing
        // space is a smaller problem than one at the start of an empty field.
        guard let previous else { return false }
        if previous.isWhitespace || previous.isNewline { return false }
        // Things you write *against*, with no space: an open bracket, an open
        // quote, a hyphen mid-word.
        if "([{<\"'“‘-–—/".contains(previous) { return false }
        return true
    }

    /// The single character immediately before the insertion point, or nil when
    /// the app doesn't say.
    private static func precedingCharacter() -> Character? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else { return nil }
        AXUIElementSetMessagingTimeout(focused, axTimeout)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let value = rangeRef as! AXValue? else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(value, .cfRange, &caret), caret.location > 0 else { return nil }

        var query = CFRange(location: caret.location - 1, length: 1)
        guard let queryValue = AXValueCreate(.cfRange, &query) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXStringForRangeParameterizedAttribute as CFString, queryValue, &textRef
        ) == .success, let preceding = textRef as? String else { return nil }
        return preceding.last
    }

    private static func fieldState() -> FieldState? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else { return nil }
        AXUIElementSetMessagingTimeout(focused, axTimeout)

        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXNumberOfCharactersAttribute as CFString, &countRef
        ) == .success, let characters = countRef as? Int else { return nil }

        var caret = -1
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let value = rangeRef as! AXValue? {
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) { caret = range.location }
        }
        return FieldState(characters: characters, caret: caret)
    }

    @discardableResult
    public func insert(_ text: String) throws -> InsertOutcome {
        // A password field blocks the paste and the event tap both. The text is
        // kept in the recent list; nothing goes near the clipboard.
        if Permissions.isSecureInputActive {
            Log.echo("insert: not typed — a password field is focused")
            return .notTyped(reason: "a password field is focused")
        }

        // Two reasons to stop at the clipboard: the user asked for that, or we
        // can't type because Accessibility isn't granted. Degrading rather than
        // failing keeps the app usable either way.
        let wantsTyping = InsertionPreference.current == .typeIntoApp
        let canType = wantsTyping && AXIsProcessTrusted()

        guard canType else {
            // Clipboard-only is the user's own setting, so it isn't news; a
            // missing permission is.
            guard wantsTyping else {
                _ = copyOnly(text, reason: "set to clipboard only")
                return .typed
            }
            return copyOnly(text, reason: "Accessibility isn't granted")
        }

        // Before pasting, not after. Whether a paste *did* land is not reliably
        // knowable — stale accessibility reads made that check fire on healthy
        // pastes. Whether there is anywhere to paste *at all* is a different
        // question, asked of the app before anything is sent, and an explicit
        // non-text role is a real answer rather than an absence of one.
        let focus = FocusProbe.probe()
        if case .notEditable(let role) = focus.focus {
            Log.echo("insert: nowhere to type — \(focus.description)")
            return .notTyped(reason: "no text field focused (\(role))")
        }
        // Recorded on every insert so the list of refusing roles can be widened
        // against what apps actually report, rather than what they ought to.
        Log.echo("insert: focus \(focus.description)")

        let previous = Self.precedingCharacter()
        let payload = Self.needsLeadingSpace(after: previous, inserting: text)
            ? " " + text
            : text
        if payload != text { Log.echo("insert: added a leading space after “\(previous.map(String.init) ?? "")”") }

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Sampled before the paste so it can be compared with after. Nil means
        // the app doesn't answer, which is common and is *not* evidence.
        let before = Self.fieldState()

        synthesizePaste()

        lastInsertWasClipboardOnly = false

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            // If the user copied something during our window, their copy wins —
            // clobbering it would be a genuinely infuriating bug.
            guard pasteboard.changeCount == ourChangeCount else { return }

            // This measurement is recorded but NOT acted on, and that is the
            // whole point of it.
            //
            // It used to decide whether to keep the text on the clipboard, on
            // the theory that "readable before and after, and nothing moved" was
            // positive evidence of a failed paste. It isn't. Across 73 real
            // insertions it fired 11 times, and every single reading reported a
            // caret at position 0 — in documents of three thousand characters.
            // Accessibility was returning stale values, not reporting a failure,
            // and the app was clobbering the clipboard and refusing to type on
            // the strength of it.
            //
            // "Accessibility didn't tell us anything changed" is not the same
            // claim as "the paste failed", and until something can tell the two
            // apart the clipboard stays untouched. Recovery lives on the menu
            // instead, where it needs no guess to be correct.
            if let before, let after = Self.fieldState(), before == after {
                Log.echo("insert: no AX change after paste (\(before.characters) chars, caret \(before.caret)) — not acted on")
            }

            Self.restore(saved, to: pasteboard)
        }

        return .typed
    }

    /// Leaves the text on the clipboard and says so. The only route by which
    /// Murmur ever replaces what the user had copied.
    @discardableResult
    private func copyOnly(_ text: String, reason: String) -> InsertOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastInsertWasClipboardOnly = true
        Log.echo("insert: clipboard (\(reason)) — \(text.count) chars")
        return .copied(reason: reason)
    }

    // MARK: - Pasteboard save/restore

    /// Deep-copies the pasteboard. `pasteboardItems` go invalid the moment we
    /// call `clearContents()`, so the data has to be pulled out first.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Event synthesis

    private func synthesizePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Don't let our synthetic ⌘V echo back into our own event tap.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
