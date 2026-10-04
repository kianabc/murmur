import Foundation

/// Runs `work` and gives up waiting after `seconds`, *actually*.
///
/// The obvious version — a task group racing the work against a sleep — does
/// not bound anything. A task group cannot return until every child has
/// finished, and cancelling a child is only a request: awaiting a speech
/// analyzer, or another task's value, ignores it. So a "three-second" limit
/// waited as long as the work did, and with no audio the analyzer never
/// finished at all. That is how a 130ms tap left the app stuck for 46 seconds,
/// until the last-resort watchdog freed it.
///
/// This one resumes the caller as soon as either side finishes and leaves the
/// loser running unstructured. The caller is responsible for tidying up the
/// abandoned work (cancelling the analyzer), which it can now actually reach.
public enum Deadline {
    public static func race(
        seconds: Double,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()
            Task {
                await work()
                if gate.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Lets exactly one of two racers resume a continuation.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
