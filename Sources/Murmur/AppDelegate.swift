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
    private var hud: DictationHUD?
    private var testBench: TestBenchWindowController?

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
        }

        // Without this, ⌘V is dead in every text field in the app.
        EditMenu.install()

        let engine = Self.makeEngine()
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
                guard AnthropicProvider.hasKey else {
                    Log.echo("cleanup: skipped — no API key readable")
                    return corrected
                }

                do {
                    let provider = AnthropicProvider(model: CleanupPreference.model)
                    let context = CleanupContext(
                        appName: app?.localizedName,
                        appBundleID: app?.bundleIdentifier,
                        vocabulary: store.vocabulary(for: app?.bundleIdentifier)
                    )
                    let result = try await provider.clean(corrected, context: context)
                    let pricing = CleanupPreference.model.pricing
                    usage?.record(UsageEvent(
                        model: CleanupPreference.model.rawValue,
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
        testBench = TestBenchWindowController(controller: controller)
        menuBar = MenuBarController(controller: controller)
        menuBar.onShowTestBench = { [weak self] in self?.testBench?.show() }
        menuBar.onShowSettings = { [weak self] in
            guard let self else { return }
            // Show the raw transcript, not the corrected one — that's the text
            // the user needs to see to teach the next fix.
            self.settings?.show(lastTranscript: self.controller.lastRawTranscript)
        }

        let granted = Permission.allCases
            .filter { permissions.state(of: $0) == .granted }
            .map(\.rawValue)
        Log.echo("launched · granted: \(granted.isEmpty ? "none" : granted.joined(separator: ", "))")
        // Deliberately does NOT read the key here. A Keychain read can raise a
        // modal prompt, and a modal prompt during applicationDidFinishLaunching
        // blocks the main thread — the app hangs before it finishes launching.
        Log.echo(String(
            format: "cleanup: %@ · model %@",
            CleanupPreference.isEnabled ? "on" : "off",
            CleanupPreference.model.rawValue
        ))

        if CommandLine.arguments.contains("--test") {
            testBench?.show()
        } else if CommandLine.arguments.contains("--settings") {
            settings?.show()
        } else {
            beginListening()
        }

        prepareEngine(engine)
        checkForUpdatesIfDue()
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

    private func beginListening() {
        guard !controller.isListening else { return }
        if controller.startListening() {
            Log.echo("listening for \(controller.hotkey.displayName)")
        } else {
            // Tap creation fails when Input Monitoring hasn't been granted.
            Log.echo("event tap refused — Input Monitoring not granted")
            settings?.show()
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
