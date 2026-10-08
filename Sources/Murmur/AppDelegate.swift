import AppKit
import MurmurASR
import MurmurCleanup
import MurmurCore
import MurmurStore
import MurmurUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController!
    private var menuBar: MenuBarController!
    private var speechEngine: SpeechAnalyzerEngine?
    private var isInstallingUpdate = false
    private var updateTimer: Timer?
    private var nudge: CleanupNudgeWindow?
    private var correctionService: CorrectionService?
    private var tour: FeatureTour?
    private var setupShown = false

    /// The tour, once — after setup has finished if setup is showing, so a new
    /// user isn't handed two windows at once.
    @MainActor
    private func showTourIfDue() {
        guard FeatureTour.isDue else { return }
        let tour = FeatureTour(
            hotkeyName: { [weak self] in self?.controller.hotkey.displayName ?? "the shortcut" },
            hasCleanupKey: { KeyStore.hasKey(for: CleanupPreference.model.provider) },
            onSetUpCleanup: { [weak self] in self?.settings?.show(tab: .cleanup) }
        )
        self.tour = tour
        Log.echo("tour: showing edition \(FeatureTour.edition)")
        tour.show()
    }

    @MainActor
    func showTour() {
        let tour = FeatureTour(
            hotkeyName: { [weak self] in self?.controller.hotkey.displayName ?? "the shortcut" },
            hasCleanupKey: { KeyStore.hasKey(for: CleanupPreference.model.provider) },
            onSetUpCleanup: { [weak self] in self?.settings?.show(tab: .cleanup) }
        )
        self.tour = tour
        tour.show()
    }

    /// The menu bar fallback for apps whose own right-click menu leaves out
    /// Services — Electron apps mostly, the Claude app and Slack among them.
    @MainActor
    private func fixAWord() {
        guard let store = correctionStore,
              let pair = CorrectionPrompt.askBoth(lastDictation: controller.lastTranscript) else { return }
        do {
            try store.learn(heard: pair.heard, meant: pair.meant)
            Log.echo("fix a word: learned \(pair.heard.count) → \(pair.meant.count) chars")
        } catch {
            CorrectionPrompt.explain("Couldn't save that correction: \(error.localizedDescription)")
        }
    }

    /// Offers to set up AI cleanup. Choosing a provider selects its cheapest
    /// model, opens the provider's key page in the browser, and opens Settings
    /// on the AI Cleanup tab where the steps and the paste field are.
    @MainActor
    private func showCleanupNudge() {
        Log.echo("nudge: offering AI cleanup")
        let nudge = CleanupNudgeWindow { [weak self] provider in
            Log.echo("nudge: chose \(provider.rawValue)")
            CleanupPreference.model = provider.defaultModel
            CleanupPreference.isEnabled = true
            NSWorkspace.shared.open(provider.keyURL)
            self?.settings?.show(tab: .cleanup)
        }
        self.nudge = nudge
        nudge.show()
    }
    private let permissions = Permissions()
    private var correctionStore: CorrectionStore?
    private var usageStore: UsageStore?
    private var settings: SettingsWindowController?
    private let setup = SetupWindowController()
    private var hud: DictationHUD?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First thing, so a crash during setup is still recorded.
        Diagnostics.begin(version: AppVersion.current)
        Diagnostics.importSystemReports()
        LaunchAtLogin.applyDefaultIfUndecided()

        // Two menu bar icons means two copies are running — easy to end up with
        // when relaunching during development, and confusing because only one of
        // them owns the hotkey.
        let mine = Bundle.main.bundleIdentifier
        let duplicates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == mine && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if !duplicates.isEmpty {
            Log.echo("another Murmur is already running — terminating \(duplicates.count) older copy/copies")
            duplicates.forEach { $0.terminate() }
            // terminate() is a polite request an app with an open window can sit
            // on, which leaves two menu bar icons and two settings windows that
            // look like two versions. Insist if it hasn't gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for copy in duplicates where !copy.isTerminated {
                    Log.echo("duplicate ignored terminate() — forcing")
                    copy.forceTerminate()
                }
            }
        }

        // Without this, ⌘V is dead in every text field in the app.
        EditMenu.install()

        let engine = SpeechAnalyzerEngine()
        speechEngine = engine
        let sink = PasteboardSink()
        controller = DictationController(engine: engine, sink: sink)
        // A paste that goes nowhere used to lose the dictation outright: the
        // clipboard was restored 150ms later, taking the transcript with it.
        sink.onPasteFallback = { [weak self] text in
            Log.echo("insert: kept \(text.count) chars on the clipboard")
            self?.controller.reportProblem("Couldn't type that — press ⌘V to paste it")
        }

        // Learned corrections run on every transcript before it's inserted.
        // Deterministic and free — and it works regardless of whether decoder
        // biasing ever does (SPEC.md §4).
        let usage = try? UsageStore(url: UsageStore.defaultURL())
        usageStore = usage

        if let store = try? CorrectionStore(url: CorrectionStore.defaultURL()) {
            correctionStore = store
            // Right-click → Correct with Murmur… in any app that offers Services.
            let service = CorrectionService(store: store)
            correctionService = service
            NSApp.servicesProvider = service
            // Tell macOS to re-read the Services this app offers, so the entry
            // appears right after an install or update rather than after a
            // logout.
            NSUpdateDynamicServices()
            let corrector = Corrector(store: store)
            controller.postProcess = { raw in
                let app = NSWorkspace.shared.frontmostApplication
                // Ledger first: deterministic, instant, and it fixes the exact
                // words the model is most likely to get wrong again.
                let corrected = corrector.apply(to: raw, appBundleID: app?.bundleIdentifier)

                guard CleanupPreference.isEnabled else {
                    Log.echo("cleanup: skipped — disabled in Settings")
                    return corrected
                }
                guard KeyStore.hasKey(for: CleanupPreference.model.provider) else {
                    Log.echo("cleanup: skipped — no API key readable")
                    if CleanupNudge.noteDictationWithoutKey() {
                        // After the text has landed, not while the user is
                        // mid-sentence somewhere else.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                            self?.showCleanupNudge()
                        }
                    }
                    return corrected
                }
                // Checked against the corrected text, not the raw: the ledger has
                // already had its say, and what matters is the length of what
                // would actually be sent.
                guard !ShortPhrasePreference.shouldSkip(corrected) else {
                    Log.echo("cleanup: skipped — \(ShortPhrasePolicy.wordCount(corrected)) words, short phrase")
                    return corrected
                }

                do {
                    let service = CleanupService(model: CleanupPreference.model)
                    let context = CleanupContext(
                        appName: app?.localizedName,
                        appBundleID: app?.bundleIdentifier,
                        vocabulary: store.vocabulary(for: app?.bundleIdentifier)
                    )
                    let result = try await service.clean(corrected, context: context)
                    let spec = CleanupPreference.model
                    let pricing = spec.pricing
                    usage?.record(UsageEvent(
                        provider: spec.provider.rawValue,
                        model: spec.id,
                        inputTokens: result.uncachedInputTokens,
                        outputTokens: result.outputTokens,
                        cacheWriteTokens: result.cacheWriteTokens,
                        cacheReadTokens: result.cacheReadTokens,
                        // Snapshotted so a later price change can't rewrite history.
                        priceInPerMTok: pricing.input,
                        priceOutPerMTok: pricing.output,
                        latencyMs: Int(result.latency * 1000),
                        guardFired: !result.usedCleanup,
                        wordCount: corrected.split(whereSeparator: \.isWhitespace).count,
                        appBundleID: app?.bundleIdentifier
                    ))
                    Log.echo(String(
                        format: "cleanup: %@ · %.0fms · %d→%d tok",
                        result.usedCleanup ? "applied" : "rejected",
                        result.latency * 1000, result.inputTokens, result.outputTokens
                    ))
                    return result.text
                } catch let CleanupError.invalidKey(provider, _) {
                    // Worth interrupting for: unlike every other failure, this
                    // one never resolves on its own.
                    Log.echo("cleanup: \(provider.rawValue) rejected the API key")
                    await MainActor.run {
                        self.controller.reportProblem("\(provider.displayName) rejected your API key")
                    }
                    return corrected
                } catch {
                    // Fail toward raw — never lose the user's words to an API problem.
                    Log.echo("cleanup unavailable: \(error.localizedDescription) — using raw")
                    return corrected
                }
            }
            settings = SettingsWindowController(
                store: store,
                usage: usage,
                hotkey: controller.hotkey,
                onHotkeyChange: { [weak self] key in self?.controller.setHotkey(key) }
            )
            Log.echo("corrections loaded: \(store.all().count)")
        } else {
            Log.echo("corrections unavailable — continuing without them")
        }

        hud = DictationHUD(controller: controller)
        settings?.onMicPolicyChange = { [weak self] policy in
            guard let speech = self?.speechEngine else { return }
            switch policy {
            case .alwaysOpen: try? speech.startAudio()
            case .onDemand: speech.stopAudio()
            }
            Log.echo("microphone policy: \(policy.rawValue)")
        }

        menuBar = MenuBarController(controller: controller)
        menuBar.onInstallUpdate = { [weak self] update in self?.offerUpdate(update) }
        menuBar.onFixWord = { [weak self] in self?.fixAWord() }
        settings?.onInstallUpdate = { [weak self] update in self?.offerUpdate(update) }
        settings?.onShowTour = { [weak self] in self?.showTour() }
        menuBar.onShowSettings = { [weak self] in
            guard let self else { return }
            // Show the raw transcript, not the corrected one — that's the text
            // the user needs to see to teach the next fix.
            self.settings?.show(lastTranscript: self.controller.lastRawTranscript)
        }

        let granted = Permission.allCases
            .filter { permissions.state(of: $0) == .granted }
            .map(\.rawValue)
        Log.echo("launched · \(AppVersion.current) · granted: \(granted.isEmpty ? "none" : granted.joined(separator: ", "))")
        // Deliberately does NOT read the key here. A Keychain read can raise a
        // modal prompt, and a modal prompt during applicationDidFinishLaunching
        // blocks the main thread — the app hangs before it finishes launching.
        Log.echo(String(
            format: "cleanup: %@ · model %@",
            CleanupPreference.isEnabled ? "on" : "off",
            CleanupPreference.model.displayName
        ))

        // Dictation always starts. A dev flag opens an extra window; it must
        // never stop the app doing its job — leaving it deaf while a settings
        // pane is up is invisible and looks like the hotkey is broken.
        beginListening()

        if CommandLine.arguments.contains("--settings") {
            let named = CommandLine.arguments.first { $0.hasPrefix("--tab=") }?
                .replacingOccurrences(of: "--tab=", with: "")
            let tab: SettingsTab? = switch named {
                case "general": .general
                case "cleanup": .cleanup
                case "corrections": .corrections
                case "permissions": .permissions
                case "about": .about
                default: nil
            }
            settings?.show(tab: tab)
        } else {
            showPermissionsIfIncomplete()
            if !setupShown {
                // A moment after launch, once the menu bar item is up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showTourIfDue() }
            }
        }

        prepareEngine(engine)
        checkForUpdatesIfDue()
        // Launch alone is not enough: a menu bar app stays open for days, and
        // one that only checked at launch never heard about a release until it
        // happened to be restarted. Look once a day; the daily-or-weekly rule
        // inside decides whether GitHub is actually contacted.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdatesIfDue() }
        }
        // Providers change prices on their own schedule; a compiled-in table
        // goes stale the moment they do.
        Task { await PriceTable.refreshIfDue() }
    }

    /// Apple's streaming recogniser. The package requires macOS 26, so there is
    /// no fallback path — an older system can't launch the app at all, which is
    /// the point: silently degrading to a stub engine looked like a working app
    /// that did nothing.
    private static func makeEngine() -> DictationEngine {
        SpeechAnalyzerEngine()
    }

    private func prepareEngine(_ engine: DictationEngine) {
        guard let speech = engine as? SpeechAnalyzerEngine else { return }

        Task {
            do {
                try await speech.prepare { progress in
                    Log.echo("model download \(Int(progress.fractionCompleted * 100))%")
                }
                // Only pre-open the microphone when the user has asked for it.
                // Otherwise it opens per dictation and macOS shows its orange
                // indicator only while we are genuinely listening.
                if MicrophonePreference.current == .alwaysOpen {
                    try speech.startAudio()
                }
                let policy = MicrophonePreference.current == .alwaysOpen
                    ? "microphone held open"
                    : "microphone opens only while dictating"
                Log.echo("engine ready (\(policy)) — hold \(self.controller.hotkey.displayName) to dictate")
            } catch {
                Log.echo("engine unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Anything the current configuration genuinely needs. Accessibility only
    /// counts when the user has asked for text to be typed into other apps.
    private var missingPermissions: [Permission] {
        var needed: [Permission] = [.microphone, .inputMonitoring]
        if InsertionPreference.current.requiresAccessibility { needed.append(.accessibility) }
        return needed.filter { permissions.state(of: $0) != .granted }
    }

    private func showPermissionsIfIncomplete() {
        // MURMUR_FORCE_SETUP exercises the first-run path on a machine where
        // everything is already granted — otherwise this branch is only
        // reachable by revoking real permissions.
        let forced = ProcessInfo.processInfo.environment["MURMUR_FORCE_SETUP"] == "1"
        let missing = missingPermissions
        guard forced || !missing.isEmpty else { return }
        setup.hotkeyName = controller.hotkey.displayName
        // A dedicated window, not a Settings tab: someone opening the app for
        // the first time shouldn't have to work out which of six tabs to look at.
        setup.onFinished = { [weak self] in
            self?.beginListening()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.showTourIfDue() }
        }
        setup.show()
        setupShown = true
        return
        Log.echo("setup incomplete — missing: \(missing.isEmpty ? "none (forced)" : missing.map(\.rawValue).joined(separator: ", "))")
        // Straight to the Permissions tab. Opening on General is how people miss
        // that anything is required at all.
        settings?.show(tab: .permissions)
    }

    private func beginListening() {
        guard !controller.isListening else { return }
        if controller.startListening() {
            Log.echo("listening for \(controller.hotkey.displayName)")
        } else {
            // Tap creation fails when Input Monitoring hasn't been granted.
            Log.echo("event tap refused — Input Monitoring not granted")
            settings?.show(tab: .permissions)
        }
    }

    /// Quiet daily check. Only logs — nothing interrupts the user, and a network
    /// failure here must never affect dictation.
    private func checkForUpdatesIfDue() {
        guard UpdatePreference.isDue else { return }
        Task {
            do {
                Log.echo("update check: looking")
                let found = try await UpdateChecker().check()
                // Only a check that reached GitHub counts. A failed one is
                // retried on the next hourly tick rather than a day later.
                UpdatePreference.lastChecked = Date()
                if let update = found {
                    // Writing it to a log file nobody opens is not telling
                    // anyone. This is why updates were being installed by hand.
                    Log.echo("update available: \(update.version)")
                    menuBar.availableUpdate = update
                    offerWhenIdle(update)
                } else {
                    Log.echo("update check: up to date")
                }
            } catch {
                Log.echo("update check failed: \(error.localizedDescription)")
            }
        }
    }

    /// A modal alert in the middle of a dictation would steal the focus the
    /// text is about to be typed into. Wait for a quiet moment.
    @MainActor
    private func offerWhenIdle(_ update: AvailableUpdate) {
        if case .idle = controller.state {
            offerUpdate(update)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.offerWhenIdle(update)
            }
        }
    }

    /// Asks, then does the whole thing. The user's part is one button.
    @MainActor
    func offerUpdate(_ update: AvailableUpdate) {
        guard !isInstallingUpdate else { return }

        guard UpdateOfferAlert.ask(version: update.version.description, notes: update.releaseNotes) else {
            Log.echo("update: declined for now")
            return
        }
        installUpdate(update)
    }

    @MainActor
    private func installUpdate(_ update: AvailableUpdate) {
        isInstallingUpdate = true
        menuBar.isInstallingUpdate = true
        let progress = UpdateProgressWindow(version: update.version.description)
        progress.show(UpdateProgress("Starting…"))
        Task {
            do {
                let staged = try await Updater().stage(update) { step in
                    Task { @MainActor in progress.show(step) }
                }
                // Replaces the app and relaunches it; this process does not
                // return from here.
                try Updater.relaunch(with: staged)
            } catch {
                progress.close()
                isInstallingUpdate = false
                menuBar.isInstallingUpdate = false
                Log.echo("update FAILED: \(error.localizedDescription)")

                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "Couldn't install the update"
                failed.informativeText = """
                \(error.localizedDescription)

                Murmur is still running and unchanged. You can download it                 yourself from the releases page.
                """
                failed.addButton(withTitle: "Open Releases Page")
                failed.addButton(withTitle: "Cancel")
                NSApp.activate()
                if failed.runModal() == .alertFirstButtonReturn,
                   let safe = UpdateChecker.trusted(update.pageURL) {
                    NSWorkspace.shared.open(safe)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.endCleanly()
        controller?.stopListening()
    }
}
