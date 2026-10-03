import AppKit
import MurmurCleanup
import MurmurCore
import SwiftUI

/// "Did you know Murmur can clean up what you say?" — shown once, after a
/// couple of dictations have gone out raw. Picks a provider, opens its key
/// page, and lands the user in Settings with the paste field and the steps
/// right there.
@MainActor
public final class CleanupNudgeWindow {
    private var window: NSWindow?
    private let onChoose: (CleanupProvider) -> Void

    public init(onChoose: @escaping (CleanupProvider) -> Void) {
        self.onChoose = onChoose
    }

    public func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = NudgeView(
            choose: { [weak self] provider in
                self?.close()
                self?.onChoose(provider)
            },
            notNow: { [weak self] in CleanupNudge.snooze(); self?.close() },
            never: { [weak self] in CleanupNudge.dismissForever(); self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Murmur"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct NudgeView: View {
    let choose: (CleanupProvider) -> Void
    let notNow: () -> Void
    let never: () -> Void
    @State private var picked: CleanupProvider = .anthropic

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Did you know Murmur can clean up what you say?")
                    .font(.title2.weight(.semibold))
                Text("Right now you're getting the raw transcript. With an AI cleanup pass, “um”s disappear, “3 — sorry, 4” becomes “4”, and *write my bike* becomes *ride my bike*. It costs well under a dollar a month, and you pay the AI provider directly — Murmur never sees your key.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("You said").font(.caption).foregroundStyle(.secondary)
                Text("“I'm trying to, um, write my bike — sorry, ride my motorcycle to work.”").foregroundStyle(.secondary)
                Text("You get").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                Text("I'm trying to ride my motorcycle to work.").fontWeight(.medium)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text("Pick one. You'll need a key from them — it takes about a minute, and the next screen walks you through it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $picked) {
                    ForEach(CleanupProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName)
                            Text(provider.costLine).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            HStack {
                Button("Don't ask again") { never() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Not now") { notNow() }
                Button("Get a \(picked.displayName.components(separatedBy: " ").first ?? "") key") { choose(picked) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
