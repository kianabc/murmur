import Foundation
import os

/// Subsystem-scoped loggers. Use `log stream --predicate 'subsystem == "com.torimi.murmur"'`
/// to watch the pipeline live, which beats print-debugging a menu bar app.
public enum Log {
    private static let subsystem = "com.torimi.murmur"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let asr = Logger(subsystem: subsystem, category: "asr")
    public static let insert = Logger(subsystem: subsystem, category: "insert")

    /// Mirrors to stderr *and* to a file.
    ///
    /// The file matters: when the app is launched with `open`, stderr goes
    /// nowhere, and a hung process never writes a crash report — so without this
    /// a freeze leaves no evidence at all. The log is the only way to see how far
    /// the pipeline got before it stopped.
    public static func echo(_ message: String) {
        let line = "[murmur] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        appendToFile(line)
    }

    /// `~/Library/Logs/Murmur/murmur.log`
    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Murmur")
        return dir.appendingPathComponent("murmur.log")
    }

    private static let fileQueue = DispatchQueue(label: "com.torimi.murmur.log")

    private static func appendToFile(_ line: String) {
        fileQueue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stamped = "\(Self.timestamp()) \(line)"
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
                // Owner-only: the log records which apps you dictate into and when.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path
                )
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
