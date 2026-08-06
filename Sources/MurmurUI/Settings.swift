import AppKit
import MurmurCleanup
import MurmurCore
import MurmurStore
import SwiftUI

// MARK: - Model

@MainActor
public final class SettingsModel: ObservableObject {
    // General
    @Published var hotkey: Hotkey { didSet { onHotkeyChange?(hotkey) } }
    @Published var insertion: InsertionMode { didSet { InsertionPreference.current = insertion } }

    // Cleanup — the key is written on commit, never from a view update.
    @Published var apiKey = ""
    @Published var hasStoredKey = false
    @Published var cleanupEnabled: Bool { didSet { CleanupPreference.isEnabled = cleanupEnabled } }
    @Published var cleanupModel: CleanupModel { didSet { CleanupPreference.model = cleanupModel } }

    // Corrections
    @Published var entries: [Correction] = []
    @Published var heard = ""
    @Published var meant = ""
    @Published var correctionError: String?
    @Published var lastTranscript = ""

    // Permissions
    @Published var permissionStates: [Permission: PermissionState] = [:]

    // Usage
    @Published var last30: UsageSummary = .empty
    @Published var allTime: UsageSummary = .empty
    @Published var byModel: [ModelUsage] = []
    @Published var trackingSince: Date?

    private let store: CorrectionStore
    private let usage: UsageStore?
    private let permissions = Permissions()
    private var promptedAccessibility = false
    var onHotkeyChange: ((Hotkey) -> Void)?

    public init(store: CorrectionStore, usage: UsageStore?, hotkey: Hotkey) {
        self.store = store
        self.usage = usage
        self.hotkey = hotkey
        self.insertion = InsertionPreference.current
        self.cleanupEnabled = CleanupPreference.isEnabled
        self.cleanupModel = CleanupPreference.model
        // Never read the stored key back. A Keychain read can raise a modal
        // prompt, and drawing a settings pane is no place for one. We only track
        // *that* a key exists; the value itself is read once, at request time.
        self.hasStoredKey = Keychain.isPresent(AnthropicProvider.keychainAccount)
        refresh()
    }

    func refresh() {
        entries = store.all()

        if let usage {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())
            last30 = usage.summary(since: cutoff)
            allTime = usage.summary(since: nil)
            byModel = usage.byModel(since: nil)
            trackingSince = usage.firstRecordedAt()
        }
        var next: [Permission: PermissionState] = [:]
        for permission in Permission.allCases { next[permission] = permissions.state(of: permission) }
        permissionStates = next
    }

    // Cleanup

    /// Writing to the Keychain can block on a system prompt, so it never happens
    /// inside a SwiftUI update — that combination used to deadlock the app.
    func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: AnthropicProvider.keychainAccount)
        AnthropicProvider.invalidateKeyCache()
        hasStoredKey = true
        // Drop it from memory — the field shows "saved" from here on.
        apiKey = ""
    }

    func clearKey() {
        Keychain.set(nil, for: AnthropicProvider.keychainAccount)
        AnthropicProvider.invalidateKeyCache()
        hasStoredKey = false
        apiKey = ""
    }



    // Corrections

    var canAdd: Bool {
        !heard.trimmingCharacters(in: .whitespaces).isEmpty
            && !meant.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func addCorrection() {
        do {
            try store.learn(heard: heard, meant: meant)
            heard = ""; meant = ""; correctionError = nil
            refresh()
        } catch {
            correctionError = error.localizedDescription
        }
    }

    func removeCorrection(_ entry: Correction) {
        try? store.forget(heard: entry.heard, meant: entry.meant, appBundleID: entry.appBundleID)
        refresh()
    }

    // Permissions

    func actionLabel(for permission: Permission) -> String {
        if permission == .accessibility, !promptedAccessibility { return "Grant" }
        return permissionStates[permission] == .undetermined ? "Grant" : "Open Settings"
    }

    func act(on permission: Permission) {
        guard permissionStates[permission] != .granted else { return }
        // Accessibility always reads as denied until granted, so there's no
        // undetermined state to key off — prompt once, then send them onward.
        if permission == .accessibility, !promptedAccessibility {
            promptedAccessibility = true
            permissions.request(permission) { [weak self] _ in self?.refresh() }
            return
        }
        if permissionStates[permission] == .undetermined {
            permissions.request(permission) { [weak self] _ in
                self?.refresh()
                if self?.permissionStates[permission] != .granted {
                    self?.permissions.openSettings(for: permission)
                }
            }
            return
        }
        permissions.openSettings(for: permission)
    }

    /// Permissions the current configuration actually needs.
    var missingRequired: [Permission] {
        var needed: [Permission] = [.microphone, .inputMonitoring]
        if insertion.requiresAccessibility { needed.append(.accessibility) }
        return needed.filter { permissionStates[$0] != .granted }
    }
}

// MARK: - Window

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupTab(model: model)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
            CorrectionsTab(model: model)
                .tabItem { Label("Corrections", systemImage: "character.cursor.ibeam") }
            UsageTab(model: model)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            PermissionsTab(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 430)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $model.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("When finished", selection: $model.insertion) {
                    ForEach(InsertionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Text output")
            } footer: {
                Text(model.insertion.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hint: String {
        let base = "Hold \(model.hotkey.displayName) and speak. Double-tap to keep recording; Esc cancels."
        guard model.hotkey.isFunctionRow else { return base }
        return base + " Requires “Use F1, F2, etc. as standard function keys” in Keyboard settings."
    }
}

private struct CleanupTab: View {
    @ObservedObject var model: SettingsModel
    @State private var editingKey = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts with AI", isOn: $model.cleanupEnabled)
            } footer: {
                Text("Removes “um”, resolves “3, sorry 4” → “4”, fixes homophones from context, and adds punctuation. Runs after your saved corrections.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.cleanupEnabled {
                Section {
                    Picker("Model", selection: $model.cleanupModel) {
                        ForEach(CleanupModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text(model.cleanupModel.tradeoff).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("API key") {
                        if model.hasStoredKey && !editingKey {
                            HStack(spacing: 8) {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Replace") { editingKey = true; keyFocused = true }
                                Button("Remove") { model.clearKey() }
                            }
                        } else {
                            HStack(spacing: 6) {
                                // Plain field, not SecureField: it has to accept
                                // ⌘V, and nobody types one of these by hand.
                                TextField("sk-ant-…", text: $model.apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($keyFocused)
                                    .onSubmit(commit)
                                Button("Save", action: commit)
                                    .disabled(model.apiKey.isEmpty)
                            }
                        }
                    }
                } footer: {
                    Text(model.hasStoredKey
                         ? "Held in your Keychain. Murmur reads it once per launch, when it first cleans a transcript."
                         : "Without a key, dictation still works — it just skips the cleanup pass.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func commit() {
        keyFocused = false
        editingKey = false
        DispatchQueue.main.async { model.saveKey() }
    }
}

private struct CorrectionsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Heard", text: $model.heard)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Should be", text: $model.meant)
                    Button("Add") { model.addCorrection() }
                        .disabled(!model.canAdd)
                }
                .textFieldStyle(.roundedBorder)

                if let error = model.correctionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Teach a correction")
            } footer: {
                Text("Applied to every transcript before the text is inserted. Corrections are only ever added here — nothing is inferred from your edits.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.lastTranscript.isEmpty {
                Section("Last dictation") {
                    Text(model.lastTranscript)
                        .textSelection(.enabled)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Saved") {
                if model.entries.isEmpty {
                    Text("Nothing taught yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Text(entry.heard).font(.body.monospaced())
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(entry.meant).font(.body.monospaced().weight(.medium))
                            Spacer()
                            Button {
                                model.removeCorrection(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UsageTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Last 30 days") {
                UsageRows(summary: model.last30)
            }

            Section {
                UsageRows(summary: model.allTime)
            } header: {
                Text("All time")
            } footer: {
                if let since = model.trackingSince {
                    Text("Since \(since.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Nothing recorded yet — usage appears here after the first cleaned transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.byModel.count > 1 {
                Section("By model") {
                    ForEach(model.byModel) { entry in
                        LabeledContent(entry.model) {
                            Text(Format.money(entry.summary.costUSD)).monospacedDigit()
                        }
                    }
                }
            }

            Section {
                Button("Refresh") { model.refresh() }
            } footer: {
                Text("Token counts come from the API's own usage figures, and each request stores the prices in effect at the time — so past costs never change if pricing does.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }
}

private struct UsageRows: View {
    let summary: UsageSummary

    var body: some View {
        LabeledContent("Tokens sent") {
            Text(Format.count(summary.sentTokens)).monospacedDigit()
        }
        LabeledContent("Tokens received") {
            Text(Format.count(summary.receivedTokens)).monospacedDigit()
        }
        LabeledContent("Cost") {
            Text(Format.money(summary.costUSD)).monospacedDigit().fontWeight(.medium)
        }
        LabeledContent("Dictations") {
            Text(Format.count(summary.dictations)).monospacedDigit()
        }
        if summary.words > 0 {
            // The figure people can actually reason about.
            LabeledContent("Per 1,000 words") {
                Text(Format.money(summary.costPerThousandWords)).monospacedDigit()
            }
        }
        if summary.guardRejections > 0 {
            LabeledContent("Rejected by guard") {
                Text("\(summary.guardRejections)").monospacedDigit().foregroundStyle(.orange)
            }
        }
    }
}

enum Format {
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Sub-cent totals are normal here, and rounding them to "$0.00" makes the
    /// tracker look broken. Show enough digits to be believable.
    static func money(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }
}

private struct PermissionsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { permission in
                    LabeledContent {
                        HStack(spacing: 8) {
                            let state = model.permissionStates[permission] ?? .undetermined
                            if state == .granted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                            } else {
                                Button(model.actionLabel(for: permission)) { model.act(on: permission) }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                            Text(permission.rationale)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Required access")
            } footer: {
                Text(model.missingRequired.isEmpty
                     ? "Everything Murmur needs is granted."
                     : "Still needed: \(model.missingRequired.map(\.title).joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(model.missingRequired.isEmpty ? Color.secondary : Color.orange)
            }

            Section {
                Button("Check again") { model.refresh() }
            } footer: {
                Text("macOS grants these in System Settings. Come back and check again after toggling one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controller

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    private let store: CorrectionStore
    private let usage: UsageStore?
    private let initialHotkey: Hotkey
    private let onHotkeyChange: (Hotkey) -> Void

    /// Built on first `show()`, never at launch. `SettingsModel.init` reads the
    /// API key from the Keychain, and a Keychain read can raise a modal prompt —
    /// during `applicationDidFinishLaunching` that blocks the main thread and the
    /// app never finishes launching.
    private var _model: SettingsModel?
    private var model: SettingsModel {
        if let _model { return _model }
        let created = SettingsModel(store: store, usage: usage, hotkey: initialHotkey)
        created.onHotkeyChange = onHotkeyChange
        _model = created
        return created
    }

    public init(
        store: CorrectionStore,
        usage: UsageStore?,
        hotkey: Hotkey,
        onHotkeyChange: @escaping (Hotkey) -> Void
    ) {
        self.store = store
        self.usage = usage
        self.initialHotkey = hotkey
        self.onHotkeyChange = onHotkeyChange
    }

    public func show(lastTranscript: String = "") {
        let model = self.model
        model.lastTranscript = lastTranscript
        model.refresh()

        // A menu-bar-only app can't take focus, so become a regular app while a
        // window is up and drop back when it closes.
        NSApp.setActivationPolicy(.regular)

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Murmur Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Persist a key that was pasted but never committed.
                self?._model?.saveKey()
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }

        // Coming back from System Settings should reflect what was just granted.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?._model?.refresh() }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }
}
