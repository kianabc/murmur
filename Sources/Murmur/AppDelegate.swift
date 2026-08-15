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
    private let permissions = Permissions()
    private var correctionStore: CorrectionStore?
    private var usageStore: UsageStore?
    private var settings: SettingsWindowController?
    private let setup = SetupWindowController()
    private var hud: DictationHUD?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        controller = DictationController(engine: engine, sink: PasteboardSink())

        // Learned corrections run on every transcript before it's inserted.
        // Deterministic and free — and it works regardless of whether decoder
        // biasing ever does (SPEC.md §4).
        let usage = try? UsageStore(url: UsageStore.defaultURL())
        usageStore = usage

        if let store = try? CorrectionStore(url: CorrectionStore.defaultURL()) {
            correctionStore = store
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
        menuBar = MenuBarController(controller: controller)
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
        }

        prepareEngine(engine)
        checkForUpdatesIfDue()
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
                try speech.startAudio()
                Log.echo("engine ready — hold \(self.controller.hotkey.displayName) to dictate")
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
        setup.onFinished = { [weak self] in self?.beginListening() }
        setup.show()
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
                if let update = try await UpdateChecker().check() {
                    Log.echo("update available: \(update.version)")
                } 
                UpdatePreference.lastChecked = Date()
            } catch {
                Log.echo("update check failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stopListening()
    }
}
