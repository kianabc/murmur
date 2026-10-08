import AppKit
import MurmurCore
import MurmurStore

/// "Correct with Murmur…" — a macOS Service, so it appears when you right-click
/// selected text in any app that supports Services.
///
/// It teaches a correction and fixes the word in place in one step: the text
/// handed back through the pasteboard replaces the selection. Corrections are
/// still only ever taught by hand — this is a quicker hand, not inference.
@MainActor
public final class CorrectionService: NSObject {
    private let store: CorrectionStore
    /// The prompt, replaceable so the flow can be tested without a dialog.
    public var ask: (_ heard: String) -> String? = { CorrectionPrompt.ask(heard: $0) }
    /// Explanations, replaceable for the same reason.
    public var explain: (_ message: String) -> Void = { CorrectionPrompt.explain($0) }

    public init(store: CorrectionStore) {
        self.store = store
    }

    public enum Selection: Equatable {
        case ok(String)
        case rejected(String)
    }

    /// What can sensibly become a correction. A correction is a word or short
    /// phrase that keeps coming out wrong; a whole paragraph would make a rule
    /// that rewrites paragraphs.
    public static func validate(_ raw: String?) -> Selection {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected("Select the word that came out wrong, then try again.") }
        guard !text.contains(where: \.isNewline) else {
            return .rejected("Select just the word or phrase that came out wrong — not several lines.")
        }
        guard text.count <= 60 else {
            return .rejected("That's a lot of text. Select just the word or phrase that came out wrong.")
        }
        return .ok(text)
    }

    /// The Service entry point. The selector's name is the plist's NSMessage.
    @objc public func correctWithMurmur(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let returnTo = NSWorkspace.shared.frontmostApplication
        defer {
            // Hand focus back, so the replaced text is where the user is looking.
            if let returnTo, returnTo != NSRunningApplication.current { returnTo.activate() }
        }

        let heard: String
        switch Self.validate(pboard.string(forType: .string)) {
        case .rejected(let why):
            Log.echo("correction service: refused — \(why)")
            explain(why)
            error.pointee = why as NSString
            return
        case .ok(let text):
            heard = text
        }

        guard let meant = ask(heard), !meant.isEmpty, meant != heard else {
            Log.echo("correction service: cancelled")
            return
        }

        do {
            try store.learn(heard: heard, meant: meant)
            Log.echo("correction service: learned \(heard.count) → \(meant.count) chars")
        } catch {
            explain("Couldn't save that correction: \(error.localizedDescription)")
            return
        }

        // Returning text replaces the selection in the app that asked.
        pboard.clearContents()
        pboard.setString(meant, forType: .string)
    }
}

/// The small dialogs. NSAlert rather than a custom window: it is the shape
/// macOS users expect for a one-question prompt, and it handles focus and
/// Return/Escape for free.
@MainActor
public enum CorrectionPrompt {
    /// "Versailles" should be… → the replacement, or nil if cancelled.
    public static func ask(heard: String) -> String? {
        let (alert, field) = makeAsk(heard: heard)
        NSApp.activate()
        // Select the whole thing, so typing replaces it.
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func makeAsk(heard: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = "Correct “\(heard)”"
        alert.informativeText = "What should it have been? Murmur will fix it here and get it right from now on."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "The right spelling"
        field.stringValue = heard
        alert.accessoryView = field
        alert.addButton(withTitle: "Correct It")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    /// Both halves, for the menu bar fallback where nothing is selected.
    /// The last dictation is shown so the misheard word can be copied from it.
    public static func askBoth(lastDictation: String) -> (heard: String, meant: String)? {
        let alert = NSAlert()
        alert.messageText = "Fix a word"
        alert.informativeText = lastDictation.isEmpty
            ? "Type what Murmur heard and what it should have been. It will get it right from now on."
            : "Your last dictation:\n“\(lastDictation.prefix(200))”\n\nType what Murmur heard and what it should have been."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8
        let heardField = NSTextField(frame: .zero)
        heardField.placeholderString = "Murmur heard…  e.g. Versailles"
        let meantField = NSTextField(frame: .zero)
        meantField.placeholderString = "It should be…  e.g. Vercel"
        for f in [heardField, meantField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(f)
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add Correction")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = heardField
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let heard = heardField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meantField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return nil }
        return (heard, meant)
    }

    public static func explain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Correct with Murmur"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
