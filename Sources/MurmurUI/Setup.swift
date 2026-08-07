import AppKit
import MurmurCore
import SwiftUI

/// First-run window.
///
/// Permissions live in a Settings tab too, but that is the wrong place to *land*
/// someone who has just opened the app for the first time: a window with six
/// tabs asks them to figure out where to look before they can do anything. This
/// has one job and says so.
@MainActor
final class SetupModel: ObservableObject {
    @Published var states: [Permission: PermissionState] = [:]
    @Published var insertion: InsertionMode = InsertionPreference.current

    private let permissions = Permissions()
    private var prompted: Set<Permission> = []

    init() { refresh() }

    /// Accessibility is only needed when typing into other apps — someone using
    /// clipboard-only shouldn't be nagged for it.
    var required: [Permission] {
        var needed: [Permission] = [.microphone, .inputMonitoring]
        if insertion.requiresAccessibility { needed.append(.accessibility) }
        return needed
    }

    var missing: [Permission] { required.filter { states[$0] != .granted } }
    var isComplete: Bool { missing.isEmpty }

    func refresh() {
        var next: [Permission: PermissionState] = [:]
        for permission in Permission.allCases { next[permission] = permissions.state(of: permission) }
        states = next
        insertion = InsertionPreference.current
    }

    func label(for permission: Permission) -> String {
        if permission == .accessibility, !prompted.contains(permission) { return "Grant" }
        return states[permission] == .undetermined ? "Grant" : "Open Settings"
    }

    func act(on permission: Permission) {
        guard states[permission] != .granted else { return }
        // Accessibility reads as denied until granted, so there's no
        // undetermined state to branch on — prompt once, then hand off.
        if permission == .accessibility, !prompted.contains(permission) {
            prompted.insert(permission)
            permissions.request(permission) { [weak self] _ in self?.refresh() }
            return
        }
        if states[permission] == .undetermined {
            permissions.request(permission) { [weak self] _ in
                self?.refresh()
                if self?.states[permission] != .granted {
                    self?.permissions.openSettings(for: permission)
                }
            }
            return
        }
        permissions.openSettings(for: permission)
    }

    func useClipboardOnly() {
        InsertionPreference.current = .clipboardOnly
        insertion = .clipboardOnly
        refresh()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var hotkeyName: String
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Murmur")
                    .font(.title2.weight(.semibold))
                Text("Hold a key, say what you mean, and the words appear wherever you're typing.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.isComplete
                 ? "You're all set."
                 : "macOS needs your permission for \(model.missing.count) thing\(model.missing.count == 1 ? "" : "s") first. This is a one-time step.")
                .font(.callout)
                .foregroundStyle(model.isComplete ? .green : .primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(model.required.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider() }
                    row(permission)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            if !model.isComplete && model.insertion.requiresAccessibility {
                // A genuine way out for anyone unwilling to grant Accessibility,
                // rather than a dead end.
                Button("I'd rather not grant Accessibility — copy to the clipboard instead") {
                    model.useClipboardOnly()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Check again") { model.refresh() }
                Spacer()
                Button(model.isComplete ? "Start dictating" : "Later") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }

            if model.isComplete {
                Text("Hold \(hotkeyName) and speak. Everything else lives in the menu bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420, alignment: .topLeading)
    }

    private func row(_ permission: Permission) -> some View {
        let state = model.states[permission] ?? .undetermined
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state == .granted ? .green : .secondary)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.headline)
                Text(permission.rationale)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if state != .granted {
                Button(model.label(for: permission)) { model.act(on: permission) }
                    .controlSize(.small)
            }
        }
        .padding(14)
    }
}

@MainActor
public final class SetupWindowController {
    private var window: NSWindow?
    private let model = SetupModel()
    private var closeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    public var onFinished: (() -> Void)?
    public var hotkeyName: String = "your dictation key"

    public init() {}

    /// True when the current configuration still needs something.
    public var isNeeded: Bool {
        model.refresh()
        return !model.isComplete
    }

    public func show() {
        model.refresh()
        NSApp.setActivationPolicy(.regular)

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SetupView(model: model, hotkeyName: hotkeyName) { [weak self] in self?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Murmur"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        self.window = window

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = NSApp.setActivationPolicy(.accessory)
                self?.onFinished?()
            }
        }

        // Returning from System Settings should reflect what was just granted.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() { window?.close() }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }
}
