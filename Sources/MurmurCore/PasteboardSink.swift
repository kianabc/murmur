import AppKit
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

        synthesizePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // If the user copied something during our window, their copy wins —
            // clobbering it would be a genuinely infuriating bug.
            guard pasteboard.changeCount == ourChangeCount else { return }
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
