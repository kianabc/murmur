import AppKit
import Darwin

/// Records how each run of the app ended.
///
/// Written because "it keeps crashing" turned out not to be crashing at all —
/// macOS had no crash report for any of it, because a process that goes silently
/// deaf and is then quit by hand never produces one. The log has to answer the
/// question by itself: whether the last run ended by request or by dying, and if
/// it died, where.
public enum Diagnostics {
    private static let sessionKey = "com.torimi.murmur.session.open"
    private static let sessionStartedKey = "com.torimi.murmur.session.startedAt"

    public static var crashLogURL: URL {
        Log.fileURL.deletingLastPathComponent().appendingPathComponent("crashes.log")
    }

    /// Call once, as early in launch as possible.
    public static func begin(version: String) {
        reportPreviousSession()
        installHandlers()

        UserDefaults.standard.set(true, forKey: sessionKey)
        UserDefaults.standard.set(Date(), forKey: sessionStartedKey)
        UserDefaults.standard.set(version, forKey: "com.torimi.murmur.session.version")
    }

    /// Call from `applicationWillTerminate`. Its *absence* is the signal.
    public static func endCleanly() {
        Log.echo("exiting cleanly")
        UserDefaults.standard.set(false, forKey: sessionKey)
    }

    private static func reportPreviousSession() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: sessionKey) != nil else { return }
        guard defaults.bool(forKey: sessionKey) else { return }

        let started = defaults.object(forKey: sessionStartedKey) as? Date
        let version = defaults.string(forKey: "com.torimi.murmur.session.version") ?? "?"
        let ran = started.map { String(format: "%.0f min", -$0.timeIntervalSinceNow / 60) } ?? "unknown"
        Log.echo("PREVIOUS RUN DID NOT EXIT CLEANLY — v\(version), started \(started.map(String.init(describing:)) ?? "?"), ran \(ran)")
        Log.echo("  (force-quit, killed, or crashed. A crash would also appear in crashes.log below.)")

        if let crashes = try? String(contentsOf: crashLogURL, encoding: .utf8),
           !crashes.isEmpty {
            let recent = crashes.split(separator: "\n").suffix(3).joined(separator: " | ")
            Log.echo("  last crash log entries: \(recent)")
        }
    }

    // MARK: - Fatal signals

    /// Signal handlers run in a context where almost nothing is legal — no
    /// allocation, no Foundation, no locks. Only `write(2)` and
    /// `backtrace_symbols_fd` are safe here, so the file descriptor is opened
    /// ahead of time and the handler does nothing but append to it.
    private nonisolated(unsafe) static var crashFD: Int32 = -1

    private static func installHandlers() {
        crashFD = open(crashLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        NSSetUncaughtExceptionHandler { exception in
            let text = """
            === uncaught exception \(Date()) ===
            \(exception.name.rawValue): \(exception.reason ?? "")
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            Diagnostics.appendToCrashLog(text)
            Log.echo("UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "")")
        }

        for fatal in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { received in
                let header = "\n=== fatal signal \(received) ===\n"
                header.withCString { _ = write(Diagnostics.crashFD, $0, strlen($0)) }

                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, count, Diagnostics.crashFD)

                // Restore the default and re-raise, so macOS still gets its own
                // report and the exit status stays honest.
                Darwin.signal(received, SIG_DFL)
                raise(received)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(fatal, &action, nil)
        }
    }

    private static func appendToCrashLog(_ text: String) {
        guard crashFD >= 0 else { return }
        text.withCString { _ = write(crashFD, $0, strlen($0)) }
    }

    // MARK: - macOS reports

    /// Folds any crash report macOS wrote for us into our own log, so one file
    /// answers the question instead of two places nobody thinks to look.
    public static func importSystemReports() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }

        let seenKey = "com.torimi.murmur.seenReports"
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        let ours = names.filter { $0.hasPrefix("Murmur") && !seen.contains($0) }
        guard !ours.isEmpty else { return }

        for name in ours {
            Log.echo("SYSTEM CRASH REPORT: \(name)")
            if let body = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                // The first lines carry the exception type and faulting thread,
                // which is the part worth having inline.
                for line in body.split(separator: "\n").prefix(24) {
                    Log.echo("  | \(line)")
                }
            }
            seen.insert(name)
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }
}
