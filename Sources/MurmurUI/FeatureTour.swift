import AppKit
import MurmurCore
import SwiftUI

/// "Four things Murmur can do" — shown once to everyone, new installs and
/// existing users alike, the first time they run a version that has it.
///
/// Murmur has no window of its own, so nothing about it is discoverable by
/// looking. Locking a recording, teaching a word, the formatting — all of it
/// was only ever found by being told.
@MainActor
public final class FeatureTour {
    /// Bump to show the tour again after a release that changes what's in it.
    public static let edition = 1
    private static let seenKey = "com.torimi.murmur.tour.seenEdition"

    public static var isDue: Bool {
        UserDefaults.standard.integer(forKey: seenKey) < edition
    }

    private var window: NSWindow?
    private let hotkeyName: () -> String
    private let hasCleanupKey: () -> Bool
    private let onSetUpCleanup: () -> Void

    public init(
        hotkeyName: @escaping () -> String,
        hasCleanupKey: @escaping () -> Bool,
        onSetUpCleanup: @escaping () -> Void
    ) {
        self.hotkeyName = hotkeyName
        self.hasCleanupKey = hasCleanupKey
        self.onSetUpCleanup = onSetUpCleanup
    }

    public func show() {
        UserDefaults.standard.set(Self.edition, forKey: Self.seenKey)
        if let window {
            NSApp.activate(); window.makeKeyAndOrderFront(nil); return
        }
        let view = TourView(
            key: hotkeyName(),
            showSetUp: !hasCleanupKey(),
            setUp: { [weak self] in self?.close(); self?.onSetUpCleanup() },
            done: { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Murmur"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct TourView: View {
    let key: String
    let showSetUp: Bool
    let setUp: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Four things worth knowing").font(.title2.weight(.semibold))
                Text("Murmur lives quietly in your menu bar. Here's what it can do.")
                    .foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    TourCard(
                        symbol: "hand.tap",
                        title: "Double-tap to keep talking",
                        detail: "Hold \(key) to talk. Double-tap it instead and Murmur keeps listening on its own — tap \(key) again, or press Return, to stop."
                    )
                    TourCard(
                        symbol: "sparkles",
                        title: "It understands what you meant",
                        detail: "With AI cleanup on, “um”s vanish, “3 — sorry, 4” becomes “4”, and “write my bike” becomes “ride my bike”."
                    )
                }
                GridRow {
                    TourCard(
                        symbol: "list.number",
                        title: "Say a list, get a list",
                        detail: "Say “first… second… third…” and it types a numbered list. Dictate an email and it arrives with a greeting, paragraphs and a sign-off. (With AI cleanup.)"
                    )
                    TourCard(
                        symbol: "character.cursor.ibeam",
                        title: "Teach it your words",
                        detail: "If a name comes out wrong, select it, right-click, and choose Correct with Murmur… (under Services in some apps). It fixes it there and gets it right from then on."
                    )
                }
            }

            HStack {
                if showSetUp {
                    Text("AI cleanup needs a key from Anthropic, OpenAI or Google — about a minute.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if showSetUp {
                    Button("Set Up AI Cleanup") { setUp() }
                    Button("Got It") { done() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Got It") { done() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private struct TourCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
