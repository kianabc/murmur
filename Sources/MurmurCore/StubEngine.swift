import Foundation

/// M0 placeholder so the hotkey → state → insert path can be exercised before
/// audio and ASR land in M1. Emits fake partials while "recording" and returns a
/// canned transcript that includes the disfluencies and self-correction the
/// cleanup pass will eventually have to handle.
public final class StubEngine: DictationEngine {
    public var onPartial: ((String) -> Void)?
    public var onLevel: ((Float) -> Void)?

    private var timer: Timer?
    private var wordIndex = 0

    private let script = [
        "um", "so", "i", "want", "to", "buy", "3", "sorry", "4", "books",
        "and", "then", "uh", "ride", "my", "bike", "to", "the", "versailles", "deploy",
    ]

    public init() {}

    public func beginCapture() throws {
        wordIndex = 0
        onPartial?("")
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self, self.wordIndex < self.script.count else { return }
            self.wordIndex += 1
            self.onPartial?(self.script.prefix(self.wordIndex).joined(separator: " "))
        }
    }

    public func cancelCapture() {
        timer?.invalidate()
        timer = nil
        wordIndex = 0
    }

    public func finishCapture() async throws -> String {
        timer?.invalidate()
        timer = nil
        let spoken = script.prefix(max(wordIndex, 1)).joined(separator: " ")
        wordIndex = 0
        return spoken
    }
}
