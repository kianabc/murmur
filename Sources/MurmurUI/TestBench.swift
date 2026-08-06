import AppKit
import Combine
import MurmurCore
import SwiftUI

/// Permission-free test harness.
///
/// The global hotkey needs Input Monitoring and pasting into other apps needs
/// Accessibility — but neither is part of the pipeline we're actually debugging.
/// Holding a button in our own window and showing the result in that same window
/// needs no permission beyond the microphone, so the whole path
/// (audio → recogniser → corrections → text) is testable without re-granting
/// anything after every rebuild.
@MainActor
final class TestBenchModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var partial = ""
    @Published var raw = ""
    @Published var corrected = ""
    @Published var micGranted = false

    private let controller: DictationController
    private let permissions = Permissions()
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController) {
        self.controller = controller
        refreshPermissions()

        controller.$state.receive(on: RunLoop.main)
            .sink { [weak self] in self?.state = $0 }.store(in: &cancellables)
        controller.$partialText.receive(on: RunLoop.main)
            .sink { [weak self] in self?.partial = $0 }.store(in: &cancellables)
        controller.$lastRawTranscript.receive(on: RunLoop.main)
            .sink { [weak self] in self?.raw = $0 }.store(in: &cancellables)
        controller.$lastTranscript.receive(on: RunLoop.main)
            .sink { [weak self] in self?.corrected = $0 }.store(in: &cancellables)
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// True when the correction ledger actually changed something — the whole
    /// point of the feature, so it's worth showing separately.
    var correctionApplied: Bool {
        !raw.isEmpty && !corrected.isEmpty && raw != corrected
    }

    func refreshPermissions() {
        micGranted = permissions.state(of: .microphone) == .granted
    }

    func requestMic() {
        permissions.request(.microphone) { [weak self] _ in self?.refreshPermissions() }
    }

    func press() {
        guard micGranted, !isRecording else { return }
        controller.startManual()
    }

    func release() {
        guard isRecording else { return }
        controller.stopManual()
    }
}

struct TestBenchView: View {
    @ObservedObject var model: TestBenchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Test Bench").font(.title2.weight(.semibold))
                Text("Hold the button and speak. Needs only the microphone — no Accessibility, no Input Monitoring.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.micGranted {
                HStack(spacing: 10) {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                    Text("Microphone access needed").font(.callout)
                    Spacer()
                    Button("Grant") { model.requestMic() }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            talkButton

            liveRow

            if !model.raw.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    resultBlock(
                        title: model.correctionApplied ? "Raw (before corrections)" : "Transcript",
                        text: model.raw,
                        emphasised: !model.correctionApplied
                    )
                    if model.correctionApplied {
                        resultBlock(title: "After corrections", text: model.corrected, emphasised: true)
                    }
                    Text("Also copied to the clipboard — press ⌘V anywhere to check it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 440, alignment: .topLeading)
        .onAppear { model.refreshPermissions() }
    }

    private var talkButton: some View {
        // A plain Button fires on release; we need press and release separately,
        // so the gesture drives it directly.
        RoundedRectangle(cornerRadius: 12)
            .fill(model.isRecording ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.85))
            .frame(height: 72)
            .overlay(
                HStack(spacing: 10) {
                    Image(systemName: model.isRecording ? "waveform" : "mic.fill")
                    Text(model.isRecording ? "Listening — release to transcribe" : "Hold to talk")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            )
            .opacity(model.micGranted ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.press() }
                    .onEnded { _ in model.release() }
            )
            .animation(.easeOut(duration: 0.15), value: model.isRecording)
    }

    @ViewBuilder
    private var liveRow: some View {
        switch model.state {
        case .recording:
            Label(model.partial.isEmpty ? "Listening…" : model.partial, systemImage: "dot.radiowaves.left.and.right")
                .font(.callout).lineLimit(3)
        case .processing:
            Label("Transcribing…", systemImage: "hourglass").font(.callout)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
        case .idle:
            Text(" ").font(.callout)
        }
    }

    private func resultBlock(title: String, text: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    (emphasised ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }
}

@MainActor
public final class TestBenchWindowController {
    private var window: NSWindow?
    private let model: TestBenchModel
    private var closeObserver: NSObjectProtocol?

    public init(controller: DictationController) {
        self.model = TestBenchModel(controller: controller)
    }

    public func show() {
        model.refreshPermissions()
        NSApp.setActivationPolicy(.regular)

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: TestBenchView(model: model)))
        window.title = "Murmur Test Bench"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
