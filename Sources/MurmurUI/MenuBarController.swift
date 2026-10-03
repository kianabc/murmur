import AppKit
import Combine
import MurmurCleanup
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
    public var onInstallUpdate: ((AvailableUpdate) -> Void)?

    public var availableUpdate: AvailableUpdate? { didSet { rebuildMenu() } }
    public var isInstallingUpdate = false { didSet { rebuildMenu() } }

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

        controller.$recent
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .murmurKeyStatusChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
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

        // A dead key is silent otherwise: cleanup just stops happening and the
        // transcript still lands, so the menu has to say it out loud.
        let rejected = CleanupProvider.allCases.filter { KeyStatusStore.status(for: $0).isRejected }
        for provider in rejected {
            let item = NSMenuItem(
                title: "⚠︎ \(provider.displayName) rejected your API key",
                action: #selector(showSettings),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        if !rejected.isEmpty { menu.addItem(.separator()) }

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

        // Recovery for a dictation that went nowhere. Deliberately something you
        // ask for: guessing whether a paste landed meant clobbering the clipboard
        // on a signal that turned out to be noise. Pick the one that went astray
        // and it is typed again, into whatever is focused now.
        if !controller.recent.isEmpty {
            let recent = NSMenuItem(title: "Type Again", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            for transcript in controller.recent {
                let preview = transcript.text.prefix(44)
                let ellipsis = transcript.text.count > 44 ? "…" : ""
                let item = NSMenuItem(
                    title: "\(clock.string(from: transcript.date))  \u{201C}\(preview)\(ellipsis)\u{201D}",
                    action: #selector(typeAgain(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = transcript.id.uuidString
                sub.addItem(item)
            }
            recent.submenu = sub
            menu.addItem(recent)
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

        if isInstallingUpdate {
            let item = NSMenuItem(title: "Updating…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else if let update = availableUpdate {
            let item = NSMenuItem(
                title: "Update to \(update.version)…",
                action: #selector(installUpdate),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

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

    @objc private func typeAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let transcript = controller.recent.first(where: { $0.id.uuidString == id })
        else { return }
        controller.insertAgain(transcript)
    }

    @objc private func installUpdate() {
        guard let update = availableUpdate else { return }
        onInstallUpdate?(update)
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
