import AppKit
import MurmurCore

/// A small window that says what the updater is doing.
///
/// Updating took eight seconds of nothing visible — download, verify, hand
/// over — before the app vanished and came back. Eight silent seconds reads as
/// a hang, and a hang during an update is the one thing that makes people
/// force-quit, which is the one thing that would actually break it.
/// The alert that offers an update, with the notes rendered rather than shown
/// as raw markdown.
@MainActor
public enum UpdateOfferAlert {
    /// Returns true if the user chose to update.
    public static func ask(version: String, notes: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Murmur \(version) is available"
        alert.informativeText = "Here's what's changed since your version."
        alert.accessoryView = ReleaseNotesView.make(markdown: notes)
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
public final class UpdateProgressWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    public init(version: String) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))

        let title = NSTextField(labelWithString: "Updating Murmur to \(version)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 62, width: 340, height: 18)

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 42, width: 340, height: 16)

        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 20, y: 18, width: 340, height: 20)
        bar.startAnimation(nil)

        content.addSubview(title)
        content.addSubview(label)
        content.addSubview(bar)

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.title = "Murmur"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
    }

    public func show(_ progress: UpdateProgress) {
        label.stringValue = progress.phase
        if let fraction = progress.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    public func close() {
        window.orderOut(nil)
    }
}
