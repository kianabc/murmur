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

    public func insert(_ text: String) throws {
        guard !Permissions.isSecureInputActive else { throw InsertError.secureInputActive }

        // Two reasons to stop at the clipboard: the user asked for that, or we
        // can't type because Accessibility isn't granted. Degrading rather than
        // failing keeps the app usable either way.
        let wantsTyping = InsertionPreference.current == .typeIntoApp
        let canType = wantsTyping && AXIsProcessTrusted()
        lastInsertWasClipboardOnly = !canType

        guard canType else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let why = wantsTyping ? "no Accessibility" : "set to clipboard only"
            Log.echo("insert: clipboard (\(why)) — \(text.count) chars")
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Sampled before the paste so it can be compared with after. Nil means
        // the app doesn't answer, which is common and is *not* evidence.
        let before = Self.fieldState()

        synthesizePaste()

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
