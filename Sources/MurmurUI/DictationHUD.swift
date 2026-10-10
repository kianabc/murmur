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

    private static let width: CGFloat = HUDLayout.width
    /// Where the panel's bottom edge sits. It grows upward from here, so the
    /// edge nearest the text being typed stays still.
    private var bottomLeft: CGPoint?
    /// Gap between the caret and the panel, so it never covers what you're typing.
    private static let gap: CGFloat = 10

    private weak var controller: DictationController?

    public init(controller: DictationController) {
        self.controller = controller
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
            .sink { [weak self] text in
                self?.model.text = text
                self?.relayout()
            }
            .store(in: &cancellables)

        controller.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.model.level = level }
            .store(in: &cancellables)
    }

    private func apply(_ state: DictationState, anchor: CaretLocator.Anchor?) {
        // Read fresh each time: the shortcut can be changed in Settings, and
        // Return is only offered when this Mac lets Murmur intercept it.
        let key = controller?.hotkey.displayName ?? "the shortcut"
        model.stopHint = controller?.returnCanStop == true
            ? "Press \(key) or Return to stop"
            : "Press \(key) to stop"
        model.state = state
        relayout()
        switch state {
        case .idle:
            hide()
        case .recording, .processing, .failed, .notice:
            show(anchor: anchor)
        }
    }

    private func show(anchor: CaretLocator.Anchor?) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }

        // Never `CaretLocator.locate()` here. The anchor is resolved off this
        // path precisely because finding the caret is a series of synchronous
        // cross-process accessibility calls — doing it before ordering the panel
        // front meant the panel appeared late or, for a short dictation, not at
        // all. Open somewhere cheap now; `$anchor` moves it when the answer
        // arrives, a few tens of milliseconds later.
        let wasVisible = panel.isVisible
        position(panel, at: anchor ?? CaretLocator.immediateAnchor())
        // Re-asserted every time rather than only at construction. A panel that
        // has been up for hours, across space switches and activation-policy
        // changes, can quietly lose these, and then ordering it front does
        // nothing you can see.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // A non-activating panel from an accessory app won't come forward with
        // the usual ordering calls.
        panel.orderFrontRegardless()

        // Ordering front is a request, not a result. When it doesn't take, the
        // panel is unrecoverable and the only fix is a new one — the same
        // "watch the symptom" rule the audio engine already follows, because
        // enumerating the causes has not worked twice now.
        if !panel.isVisible {
            Log.echo("hud: panel would not show — rebuilding it")
            panel.orderOut(nil)
            let fresh = makePanel()
            self.panel = fresh
            position(fresh, at: anchor ?? CaretLocator.immediateAnchor())
            fresh.orderFrontRegardless()
        }

        if !wasVisible, let shown = self.panel {
            Log.echo(
                "hud: shown at \(Int(shown.frame.origin.x)),\(Int(shown.frame.origin.y))"
                + " visible=\(shown.isVisible) onScreen=\(shown.occlusionState.contains(.visible))"
            )
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: model.height),
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
    /// Taller than any one line of text. Above this the rect is a region — a
    /// terminal view, a document body, a whole window — not a caret.
    public static let caretHeightLimit: CGFloat = 120

    private func position(_ panel: NSPanel, at anchor: CaretLocator.Anchor) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.rect) } ?? NSScreen.main
        // Placed as if already at full height, then drawn at its current
        // height from the same bottom edge. Growing upward into that reserved
        // room can't cover the line being typed on or run off the screen.
        bottomLeft = Self.origin(
            for: anchor,
            size: CGSize(width: Self.width, height: HUDLayout.maxHeight),
            within: screen?.visibleFrame
        )
        resize(panel)
    }

    private func resize(_ panel: NSPanel) {
        guard let bottomLeft else { return }
        let frame = NSRect(x: bottomLeft.x, y: bottomLeft.y, width: Self.width, height: model.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// What to show and how tall to be, for the current state and text.
    private func relayout() {
        switch model.state {
        case .recording(let latched):
            let fit = HUDLayout.tail(of: model.text.isEmpty ? "Listening…" : model.text)
            model.shown = fit.text
            model.height = HUDLayout.height(transcriptLines: fit.lines, hint: latched)
        case .processing:
            let fit = HUDLayout.tail(of: model.text.isEmpty ? "Transcribing…" : model.text)
            model.shown = fit.text
            model.height = HUDLayout.height(transcriptLines: fit.lines, hint: false)
        case .failed(let reason):
            model.shown = reason
            model.height = HUDLayout.height(transcriptLines: min(2, HUDLayout.tail(of: reason).lines), hint: false)
        case .notice(let title, _):
            model.shown = title
            model.height = HUDLayout.noticeHeight
        case .idle:
            return
        }
        if let panel, panel.isVisible { resize(panel) }
    }

    /// Where the panel goes. Pure geometry, no AppKit state, because this is the
    /// part that has been wrong twice: once putting the HUD in a screen corner
    /// for fullscreen windows, once pinning it to the top of the screen in any
    /// terminal or editor.
    public static func origin(
        for anchor: CaretLocator.Anchor,
        size: CGSize,
        within visible: CGRect?
    ) -> CGPoint {
        let rect = anchor.rect
        var x = rect.minX
        var y = rect.minY - size.height - gap

        // Judge by the size of the rect, not by which rung produced it. The old
        // test asked whether the precision was `.window`, which turned out to be
        // 0 of 968 real anchors — almost everything reports as `.element`, and in
        // a terminal or an editor that "element" is the entire text view. Placing
        // the HUD just *outside* a rect that tall sends it off the bottom of the
        // screen, then off the top when it flips, and the clamp below parks it
        // against the top edge. That is the "why is it at the top" report.
        //
        // When the rect is too big to be a caret we don't know where the caret
        // is, so sit inside it, bottom-centre — where macOS puts its own
        // dictation indicator, and near where the text is being entered.
        if rect.height > caretHeightLimit {
            x = rect.midX - size.width / 2
            y = rect.minY + 48
        }

        guard let visible else { return CGPoint(x: x, y: y) }

        // Above the caret instead, if there's no room below.
        if y < visible.minY { y = rect.maxY + gap }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var text: String = ""
    @Published var level: Float = 0
    /// How to stop a locked recording, named from the user's own settings.
    @Published var stopHint: String = ""
    /// The part of the transcript that fits — the last few lines, cut at a line
    /// start — and the height that makes room for it.
    @Published var shown: String = ""
    @Published var height: CGFloat = HUDLayout.height(transcriptLines: 1, hint: false)
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: HUDLayout.spacing) {
            leading
                .frame(width: HUDLayout.leadingWidth)

            if case .notice(let title, let detail) = model.state {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            VStack(alignment: .leading, spacing: HUDLayout.hintSpacing) {
                // Already cut to the lines that fit; wraps exactly as measured.
                Text(model.shown)
                    .font(Font(HUDLayout.transcriptFont))
                    .lineLimit(isError ? 2 : HUDLayout.maxTranscriptLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: HUDLayout.textWidth, alignment: .leading)
                    .foregroundStyle(isError ? .red : .primary)
                // A locked recording runs until told to stop, so say how — with
                // the user's own shortcut, not a generic "tap to stop".
                if isLatched {
                    Text(model.stopHint)
                        .font(Font(HUDLayout.hintFont))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, HUDLayout.horizontalPadding)
        .frame(width: HUDLayout.width, height: model.height, alignment: .leading)
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
        case .notice:
            // Orange, in a soft tile: something did go wrong, so it should
            // read as a problem — but a recoverable one, not the red of a loss.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
        case .idle:
            EmptyView()
        }
    }

    private var isLatched: Bool {
        if case .recording(latched: true) = model.state { return true }
        return false
    }

    private var isError: Bool {
        if case .failed = model.state { return true }
        return false
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
