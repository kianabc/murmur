import AVFoundation
import Foundation
import MurmurAudio
import MurmurCore
import Speech

public enum SpeechEngineError: LocalizedError {
    case localeUnsupported(String)
    case notPrepared
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let id): "Speech recognition isn't available for \(id)"
        case .notPrepared: "Speech engine is still starting up"
        case .noAudioFormat: "No audio format compatible with the transcriber"
        }
    }
}

/// Dictation engine backed by Apple's `SpeechAnalyzer` (macOS 26+).
///
/// This is the streaming path. Unlike Parakeet — which is offline and has to
/// decode the whole utterance *after* you let go of the key — results arrive
/// while you speak, so the transcript is essentially ready at key release. That
/// keeps the post-release tail to just the cleanup pass. See SPEC.md §3.6.
///
/// Three capabilities here map straight onto the design:
///   • `AnalysisContext.contextualStrings` — vocabulary biasing (§4 layer 1)
///   • `SFCustomLanguageModelData.CustomPronunciation` — per-name pronunciations,
///     the fix for names that spelling alone can't carry
///   • `Result.alternatives` — n-best, which phase-2 cleanup wants (§3.4)
public final class SpeechAnalyzerEngine: DictationEngine {
    public var onPartial: ((String) -> Void)?

    public var onLevel: ((Float) -> Void)? {
        get { capture.onLevel }
        set { capture.onLevel = newValue }
    }

    /// Terms to bias the recogniser toward. Applied on the next capture.
    public var vocabulary: [String] = []

    private let locale: Locale
    private let capture: AudioCapture

    /// Resolved in `prepare()`; a fresh transcriber is built per capture.
    private var audioFormat: AVAudioFormat?
    private var isPrepared = false

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// `start()` is async but `beginCapture()` isn't, so the start is a task we
    /// must await before finalising — otherwise finalise can race ahead of start
    /// and the results stream never terminates.
    private var startTask: Task<Void, Never>?
    private var buffersSent = 0

    /// Text state is written by the results task and read on the main thread, so
    /// it needs a lock. Swift strings are copy-on-write; mutating one from two
    /// threads at once is a reliable crash, not a benign race.
    private let textLock = NSLock()
    private var _finalized = ""
    private var _volatile = ""

    private var combinedText: String {
        textLock.lock()
        defer { textLock.unlock() }
        return (_finalized + _volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synchronous on purpose: taking a lock directly inside an `async` function
    /// risks suspending while holding it, which Swift 6 rejects outright.
    private func record(_ text: String, isFinal: Bool) -> String {
        textLock.lock()
        defer { textLock.unlock() }
        if isFinal {
            // Committed. Volatile text is superseded, not appended to.
            _finalized += text
            _volatile = ""
        } else {
            _volatile = text
        }
        return (_finalized + _volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetText() {
        textLock.lock()
        _finalized = ""
        _volatile = ""
        textLock.unlock()
    }

    public init(locale: Locale = .current, capture: AudioCapture = AudioCapture()) {
        self.locale = locale
        self.capture = capture
    }

    // MARK: - Setup

    /// Resolves the model, downloads it if the OS doesn't have it yet, and warms
    /// the audio engine. Call once at launch.
    ///
    /// `progress` reports the model download — the first run on a machine has to
    /// fetch it, and it's large enough that the UI has to say so.
    public func prepare(onDownloadProgress: ((Progress) -> Void)? = nil) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SpeechEngineError.localeUnsupported(locale.identifier)
        }

        // `progressiveTranscription` is what makes this streaming: volatile
        // results land while you're still speaking.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Only download when the locale genuinely isn't installed. The API hands
        // back an installation request even for already-installed locales, and
        // calling downloadAndInstall() on one of those throws an opaque
        // NSError — so gate on installedLocales rather than on request != nil.
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }

        if !isInstalled,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.asr.info("downloading speech model for \(self.locale.identifier, privacy: .public)")
            onDownloadProgress?(request.progress)
            try await request.downloadAndInstall()
        }

        // Reservation is advisory — it returns false when the locale is already
        // accounted for. Not a failure, so don't treat it as one.
        let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
        Log.asr.debug("locale reserved: \(reserved, privacy: .public)")

        // Let the transcriber pick the format. Note it asks for Int16 @ 16 kHz,
        // not Float32 — don't hardcode a guess here.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechEngineError.noAudioFormat
        }

        audioFormat = format
        isPrepared = true
        capture.setTargetFormat(format)
        Log.echo("engine: model ready · \(Int(format.sampleRate)) Hz \(format.commonFormat.rawValue)")
    }

    /// Opens the microphone and leaves the engine warm. Separate from `prepare()`
    /// because file transcription and benchmarking need the model but not the
    /// mic — and warming the mic without permission throws.
    public func startAudio() throws {
        try capture.warmUp()
    }

    public func stopAudio() {
        capture.shutDown()
    }

    // MARK: - DictationEngine

    public func beginCapture() throws {
        guard isPrepared else { throw SpeechEngineError.notPrepared }
        Log.echo("engine: begin")

        resetText()
        buffersSent = 0

        // A fresh transcriber per capture. `results` is a single-use sequence —
        // reusing one module across sessions leaves the second session listening
        // to a stream that already finished.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Bias toward the user's own words. Settable per capture, so per-app
        // vocabulary weighting (§4) just means changing this list.
        let terms = vocabulary
        let context = AnalysisContext()
        if !terms.isEmpty {
            context.contextualStrings = [.general: terms]
        }

        resultsTask = Task { [weak self] in
            await self?.consume(transcriber: transcriber)
        }

        // Capture the continuation *by value*. Reading `self.inputContinuation`
        // from the audio thread while main mutates it is a data race on an
        // Optional — and this closure runs on the realtime audio thread.
        capture.onBuffer = { [weak self] buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
            self?.countBuffer()
        }

        // Pre-roll first, so a syllable spoken before the key registered survives.
        let preRoll = capture.beginCapture()
        for buffer in preRoll {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        Log.echo("engine: capturing (pre-roll \(preRoll.count) buffers)")

        startTask = Task {
            do {
                if !terms.isEmpty { try await analyzer.setContext(context) }
                try await analyzer.start(inputSequence: stream)
                Log.echo("engine: analyzer started")
            } catch {
                Log.echo("engine: analyzer failed to start — \(error)")
            }
        }
    }

    private func countBuffer() {
        textLock.lock()
        buffersSent += 1
        textLock.unlock()
    }

    private var bufferCount: Int {
        textLock.lock()
        defer { textLock.unlock() }
        return buffersSent
    }

    public func finishCapture() async throws -> String {
        let level = capture.levelReport()
        Log.echo(String(
            format: "engine: finish · %d buffers · %.1fs · peak %.3f%@",
            bufferCount, level.seconds, level.peak,
            level.peak < 0.001 ? "  ← SILENT, audio never reached the mic" : ""
        ))
        capture.onBuffer = nil
        capture.endCapture()
        inputContinuation?.finish()
        inputContinuation = nil

        // The analyzer may still be starting — finalising before it started
        // leaves the results stream open forever. Bounded, because when the mic
        // has gone silent this never completes, and an unbounded await here hung
        // finalize forever and wedged the whole app in "Transcribing…".
        if let startTask {
            let started = await Self.withTimeout(seconds: 2) { await startTask.value }
            if !started {
                Log.echo("engine: analyzer never finished starting — abandoning it")
                startTask.cancel()
            }
        }
        startTask = nil

        let analyzer = self.analyzer
        self.analyzer = nil

        // Everything past here is bounded. A stuck drain used to leave the UI
        // pinned on "Transcribing…" with no way out; now it gives up and returns
        // whatever it has, which is the fail-toward-raw rule (SPEC.md §1).
        let finished = await Self.withTimeout(seconds: 3) {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await self.resultsTask?.value
        }
        if !finished {
            Log.echo("engine: drain timed out — returning partial")
            resultsTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
        resultsTask = nil

        let text = combinedText
        resetText()
        Log.echo("engine: transcript \(text.count) chars")
        return text
    }

    /// Runs `work`, returning false if it didn't finish in time.
    private static func withTimeout(seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    public func cancelCapture() {
        capture.onBuffer = nil
        capture.endCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        startTask?.cancel()
        startTask = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }

        resetText()
        Log.echo("engine: cancelled")
    }

    // MARK: - File transcription (testing + benchmarking)

    /// Runs an audio file through the same analyzer and result-handling code the
    /// live path uses. Exists so the transcription logic — especially the
    /// volatile-vs-finalized accumulation, which is the easiest thing to get
    /// wrong — can be verified without a microphone or TCC permissions.
    ///
    /// Also the benchmark hook: the returned duration is decode wall-clock.
    public func transcribeFile(at url: URL) async throws -> (text: String, duration: TimeInterval) {
        guard isPrepared else { throw SpeechEngineError.notPrepared }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        resetText()

        let file = try AVAudioFile(forReading: url)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: file.processingFormat
        ) else {
            throw SpeechEngineError.noAudioFormat
        }

        let converter = AVAudioConverter(from: file.processingFormat, to: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let started = Date()
        let consumer = Task { [weak self] in await self?.consume(transcriber: transcriber) }

        // Same biasing the live path applies — otherwise this harness silently
        // tests a different pipeline than the one that ships.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }

        try await analyzer.start(inputSequence: stream)

        let chunk: AVAudioFrameCount = 4096
        while true {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            // read() throws at end-of-file rather than returning zero frames.
            do { try file.read(into: input, frameCount: chunk) } catch { break }
            if input.frameLength == 0 { break }
            continuation.yield(AnalyzerInput(buffer: Self.resample(input, with: converter, to: format) ?? input))
        }
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await consumer.value

        let text = combinedText
        resetText()
        return (text, Date().timeIntervalSince(started))
    }

    private static func resample(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter, buffer.format != format else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    // MARK: - Results

    private func consume(transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let combined = record(String(result.text.characters), isFinal: result.isFinal)
                onPartial?(combined)
            }
        } catch is CancellationError {
            // Esc — nothing to report.
        } catch {
            Log.asr.error("results stream ended: \(error.localizedDescription, privacy: .public)")
        }
    }
}
