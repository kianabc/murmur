import AppKit
import Combine
import MurmurCore

/// The menu bar item. Its icon is the primary status display — users need to
/// know at a glance whether Murmur is listening, recording, or wedged.
@MainActor
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let permissions = Permissions()
    private var cancellables = Set<AnyCancellable>()

    public var onShowSettings: (() -> Void)?

    public init(controller: DictationController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        rebuildMenu()

        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.apply(state)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    // MARK: - Appearance

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(for: .idle)
        button.image?.isTemplate = true
        button.toolTip = "Murmur"
    }

    private func apply(_ state: DictationState) {
        guard let button = statusItem.button else { return }
        button.image = Self.icon(for: state)
        button.image?.isTemplate = true

        switch state {
        case .idle: button.toolTip = "Murmur — hold \(controller.hotkey.displayName)"
        case .recording(let latched): button.toolTip = latched ? "Recording (latched)" : "Recording"
        case .processing: button.toolTip = "Transcribing…"
        case .failed(let reason): button.toolTip = reason
        }
    }

    private static func icon(for state: DictationState) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "mic"
        case .recording(let latched): name = latched ? "mic.badge.plus" : "mic.fill"
        case .processing: name = "waveform"
        case .failed: name = "mic.slash"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(statusRow())
        menu.addItem(.separator())

        if !permissions.allGranted {
            let item = NSMenuItem(
                title: "Finish setup…",
                action: #selector(showSettings),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !controller.lastTranscript.isEmpty {
            let preview = String(controller.lastTranscript.prefix(48))
            let item = NSMenuItem(title: "Last: \u{201C}\(preview)\u{201D}", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Works without Input Monitoring — the whole point of the test bench.
        let dictate = NSMenuItem(
            title: controller.state.isActive ? "Stop dictating" : "Start dictating",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        dictate.target = self
        menu.addItem(dictate)

        menu.addItem(.separator())

        let fix = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        fix.target = self
        menu.addItem(fix)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func statusRow() -> NSMenuItem {
        let title: String
        switch controller.state {
        case .idle:
            title = controller.isListening ? "Ready — hold \(controller.hotkey.displayName)" : "Not listening"
        case .recording(let latched):
            title = latched ? "Recording (tap fn to stop)" : "Recording…"
        case .processing:
            title = "Transcribing…"
        case .failed(let reason):
            title = reason
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func showSettings() {
        onShowSettings?()
    }

    @objc private func toggleDictation() {
        controller.toggleManual()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
