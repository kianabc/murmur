import AppKit
import MurmurCleanup
import MurmurCore
import MurmurStore
import SwiftUI

/// Tabs are addressable so the app can open straight to the one that matters —
/// landing a first-time user on General when they need Permissions is how the
/// setup step gets missed.
public enum SettingsTab: Hashable, Sendable {
    case general, cleanup, corrections, permissions, about
}

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
    /// Changing provider moves the model to that provider's cheapest, which is
    /// also the sensible default — nobody wants to be dropped onto the priciest
    /// option by switching vendors.
    @Published var cleanupProvider: CleanupProvider {
        didSet {
            guard cleanupProvider != oldValue else { return }
            cleanupModel = cleanupProvider.defaultModel
            apiKey = ""
            hasStoredKey = Keychain.isPresent(cleanupProvider.keychainAccount)
        }
    }
    @Published var cleanupModel: CleanupModelSpec { didSet { CleanupPreference.model = cleanupModel } }

    // Corrections
    @Published var entries: [Correction] = []
    @Published var heard = ""
    @Published var meant = ""
    @Published var correctionError: String?
    @Published var lastTranscript = ""

    // Permissions
    @Published var permissionStates: [Permission: PermissionState] = [:]
    @Published var selectedTab: SettingsTab = .general

    // Updates
    @Published var updateStatus = ""
    @Published var availableUpdate: AvailableUpdate?
    @Published var checkingForUpdate = false
    @Published var autoCheckUpdates = UpdatePreference.automatic {
        didSet { UpdatePreference.automatic = autoCheckUpdates }
    }

    var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func checkForUpdates() {
        guard !checkingForUpdate else { return }
        checkingForUpdate = true
        updateStatus = "Checking…"
        Task {
            let checker = UpdateChecker()
            do {
                let found = try await checker.check()
                UpdatePreference.lastChecked = Date()
                await MainActor.run {
                    availableUpdate = found
                    updateStatus = found.map { "Version \($0.version) is available." }
                        ?? "You're up to date."
                    checkingForUpdate = false
                }
            } catch {
                await MainActor.run {
                    updateStatus = error.localizedDescription
                    checkingForUpdate = false
                }
            }
        }
    }

    // Usage
    @Published var last7: UsageSummary = .empty
    @Published var last30: UsageSummary = .empty
    @Published var allTime: UsageSummary = .empty
    @Published var byProvider: [ProviderUsage] = []
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
        self.cleanupProvider = CleanupPreference.model.provider
        // Never read the stored key back. A Keychain read can raise a modal
        // prompt, and drawing a settings pane is no place for one. We only track
        // *that* a key exists; the value itself is read once, at request time.
        self.hasStoredKey = Keychain.isPresent(CleanupPreference.model.provider.keychainAccount)
        refresh()
    }

    func refresh() {
        entries = store.all()

        if let usage {
            let cal = Calendar.current
            last7 = usage.summary(since: cal.date(byAdding: .day, value: -7, to: Date()))
            last30 = usage.summary(since: cal.date(byAdding: .day, value: -30, to: Date()))
            allTime = usage.summary(since: nil)
            byProvider = usage.byProvider(since: nil)
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
        Keychain.set(trimmed, for: cleanupProvider.keychainAccount)
        KeyStore.invalidate(cleanupProvider)
        hasStoredKey = true
        // Drop it from memory — the field shows "saved" from here on.
        apiKey = ""
    }

    func clearKey() {
        Keychain.set(nil, for: cleanupProvider.keychainAccount)
        KeyStore.invalidate(cleanupProvider)
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
        TabView(selection: $model.selectedTab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CleanupTab(model: model)
                .tabItem { Label("AI Cleanup", systemImage: "sparkles") }
                .tag(SettingsTab.cleanup)
            CorrectionsTab(model: model)
                .tabItem { Label("Corrections", systemImage: "character.cursor.ibeam") }
                .tag(SettingsTab.corrections)
            PermissionsTab(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            AboutTab(model: model)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: 580)
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
                    Picker("Provider", selection: $model.cleanupProvider) {
                        ForEach(CleanupProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Model", selection: $model.cleanupModel) {
                        // Cheapest first, so cost rises as you scroll down.
                        ForEach(model.cleanupProvider.models) { spec in
                            Text("\(spec.displayName)  ·  \(spec.monthlyEstimate)").tag(spec)
                        }
                    }
                } footer: {
                    Text(model.cleanupModel.blurb).font(.caption).foregroundStyle(.secondary)
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
                                TextField(model.cleanupProvider.keyPrefixHint, text: $model.apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($keyFocused)
                                    .onSubmit(commit)
                                Button("Save", action: commit)
                                    .disabled(model.apiKey.isEmpty)
                            }
                        }
                    }
                } footer: {
                    if model.hasStoredKey {
                        Text("Held in your Keychain. Keys are kept per provider, so switching back doesn't lose one.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Text("Without a key, dictation still works — it just skips the cleanup pass.")
                            Link("Get a key", destination: model.cleanupProvider.keyURL)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        UsageCard(title: "Last 7 days", summary: model.last7)
                        UsageCard(title: "Last 30 days", summary: model.last30)
                        UsageCard(title: "All time", summary: model.allTime, highlighted: true)
                    }
                    .padding(.vertical, 2)
                } header: {
                    HStack {
                        Text("What you've spent")
                        Spacer()
                        Button("Refresh") { model.refresh() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    if model.byProvider.count > 1 {
                        // Each vendor bills separately, so a combined total
                        // can't be reconciled against either invoice.
                        Divider().padding(.vertical, 2)
                        ForEach(model.byProvider) { entry in
                            LabeledContent(Format.providerName(entry.provider)) {
                                Text(Format.money(entry.summary.costUSD))
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                } footer: {
                    Text(model.allTime.dictations == 0
                         ? "Nothing yet — figures appear after your first cleaned transcript."
                         : "Counts come from each API's own usage figures. Every request stores the prices in force at the time, so past costs never change when pricing does.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
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

private struct AboutTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: model.appVersion)
                LabeledContent("Requires", value: "macOS 26 or later")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $model.autoCheckUpdates)

                HStack {
                    Button(model.checkingForUpdate ? "Checking…" : "Check now") {
                        model.checkForUpdates()
                    }
                    .disabled(model.checkingForUpdate)

                    if let update = model.availableUpdate {
                        Link("Download \(update.version.description)", destination: update.pageURL)
                    }
                }

                if !model.updateStatus.isEmpty {
                    Text(model.updateStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks GitHub for a newer release once a day. Murmur tells you and opens the download page — it never installs anything on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Link("Source and issues", destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
                Link("Release notes", destination: URL(string: "https://github.com/\(UpdateChecker.repository)/blob/main/CHANGELOG.md")!)
            }
        }
        .formStyle(.grouped)
    }
}

enum Format {
    static func providerName(_ raw: String) -> String {
        CleanupProvider(rawValue: raw)?.displayName ?? raw
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Token counts run to six figures; "412k" reads at a glance where
    /// "412,338" just becomes noise on a small card.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func money(_ value: Double) -> String { Money.format(value) }
}

/// One period's spend. The cost is the headline because it's the number people
/// actually want; tokens are the supporting detail, not the other way round.
private struct UsageCard: View {
    let title: String
    let summary: UsageSummary
    var highlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(Format.money(summary.costUSD))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)

            VStack(alignment: .leading, spacing: 2) {
                detail("\(Format.count(summary.dictations)) dictations")
                detail("\(Format.compact(summary.sentTokens)) sent · \(Format.compact(summary.receivedTokens)) back")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(highlighted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.09))
        )
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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
                     ? "Everything Murmur needs is granted. Hold your dictation key and speak."
                     : "Still needed: \(model.missingRequired.map(\.title).joined(separator: ", ")). Click Grant on each — macOS opens System Settings, you flip the switch, then come back and click Check again.")
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

    public func show(lastTranscript: String = "", tab: SettingsTab? = nil) {
        let model = self.model
        model.lastTranscript = lastTranscript
        if let tab {
            model.selectedTab = tab
            Log.echo("settings: opening on \(tab) tab")
        }
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
        window.styleMask = [.titled, .closable, .resizable]
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
