import AppKit
import Combine
import MurmurCore
import SwiftUI

/// Floating status panel, anchored beside the text caret.
///
/// It shows the raw transcript as it arrives — deliberately raw, because seeing
/// the words land is what makes the wait feel instant (SPEC.md §3.3) — and a
/// level meter driven by the actual microphone signal, so "it's hearing me" is
/// something you can see rather than infer.
@MainActor
public final class DictationHUD {
    private var panel: NSPanel?
    private let model = HUDModel()
    private var cancellables = Set<AnyCancellable>()

    private static let width: CGFloat = 360
    private static let height: CGFloat = 60
    /// Gap between the caret and the panel, so it never covers what you're typing.
    private static let gap: CGFloat = 10

    public init(controller: DictationController) {
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state, anchor: controller.anchor) }
            .store(in: &cancellables)

        // The anchor arrives a beat after the HUD does, so the panel opens where
        // it can and moves to the caret when accessibility answers.
        controller.$anchor
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] anchor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel, at: anchor)
            }
            .store(in: &cancellables)

        controller.$partialText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.model.text = text }
            .store(in: &cancellables)

        controller.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.model.level = level }
            .store(in: &cancellables)
    }

    private func apply(_ state: DictationState, anchor: CaretLocator.Anchor?) {
        model.state = state
        switch state {
        case .idle:
            hide()
        case .recording, .processing, .failed:
            show(anchor: anchor)
        }
    }

    private func show(anchor: CaretLocator.Anchor?) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        position(panel, at: anchor ?? CaretLocator.locate())
        // A non-activating panel from an accessory app won't come forward with
        // the usual ordering calls.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: HUDView(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // fullScreenAuxiliary is what lets it appear over a fullscreen app —
        // without it the HUD is invisible exactly when you're concentrating.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// Sits just below the caret, nudged back on-screen if that would overflow.
    private func position(_ panel: NSPanel, at anchor: CaretLocator.Anchor) {
        let rect = anchor.rect
        var x = rect.minX
        var y = rect.minY - Self.height - Self.gap

        // Knowing only the window is not knowing where the caret is, and placing
        // the HUD just outside a window-sized rect goes badly: for a fullscreen
        // window "just below" is off the bottom of the screen, "just above" is
        // off the top, and the clamp below drops it in a corner — present, but
        // nowhere near where anyone is looking. Sit inside the window instead,
        // bottom-centre, which is where macOS puts its own dictation indicator.
        if anchor.precision == .window {
            x = rect.midX - Self.width / 2
            y = rect.minY + 48
        }

        // Above the caret instead, if there's no room below.
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if y < visible.minY { y = rect.maxY + Self.gap }
            x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - Self.height - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var text: String = ""
    @Published var level: Float = 0
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 11) {
            leading

            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isError ? .red : .primary)
                // New words push in from the trailing edge rather than snapping.
                .animation(.easeOut(duration: 0.12), value: model.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 360, height: 60, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .recording:
            LevelMeter(level: model.level)
        case .processing:
            ThinkingDots()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var isError: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var label: String {
        switch model.state {
        case .recording(let latched):
            if !model.text.isEmpty { return model.text }
            return latched ? "Listening — tap to stop" : "Listening…"
        case .processing:
            return model.text.isEmpty ? "Transcribing…" : model.text
        case .failed(let reason):
            return reason
        case .idle:
            return ""
        }
    }
}

/// Five bars that rise and fall with the microphone signal.
///
/// Each bar is weighted differently and lags slightly, so the whole thing ripples
/// instead of moving as one block — that's what reads as "alive" rather than as a
/// progress bar.
private struct LevelMeter: View {
    let level: Float

    private static let weights: [Float] = [0.55, 0.85, 1.0, 0.8, 0.5]
    private static let barWidth: CGFloat = 3
    private static let maxHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { index, weight in
                Capsule()
                    .fill(Color.red.opacity(0.9))
                    .frame(width: Self.barWidth, height: height(for: weight))
                    .animation(
                        .spring(response: 0.22, dampingFraction: 0.55)
                            .delay(Double(index) * 0.015),
                        value: level
                    )
            }
        }
        .frame(width: 27, height: Self.maxHeight)
    }

    private func height(for weight: Float) -> CGFloat {
        // Speech is roughly logarithmic; a linear meter barely moves at normal
        // talking volume. This makes ordinary speech use most of the range.
        let boosted = min(1, sqrt(max(0, level)) * 1.6)
        let minimum: CGFloat = 3
        return minimum + CGFloat(boosted * weight) * (Self.maxHeight - minimum)
    }
}

/// Three dots cycling while the transcript is being finalised.
private struct ThinkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(scale(for: index))
                    .opacity(0.45 + 0.55 * scale(for: index))
            }
        }
        .frame(width: 27)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func scale(for index: Int) -> Double {
        let distance = abs(phase - Double(index)).truncatingRemainder(dividingBy: 3)
        return 0.6 + 0.4 * max(0, 1 - distance)
    }
}
