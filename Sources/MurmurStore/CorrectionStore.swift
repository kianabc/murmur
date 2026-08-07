import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct Correction: Sendable, Equatable {
    public let heard: String
    public let meant: String
    public let appBundleID: String?
    public let count: Int
    public let active: Bool
}

/// Append-only-ish ledger of `heard → meant` pairs.
///
/// The unit is the *pair*, not the word: you're learning the specific mishearing,
/// so "Versell" and "Verscel" are separate rows both pointing at "Vercel", and
/// both get fixed. A plain word list couldn't express that.
///
/// This is layer 2 of the vocabulary design (SPEC.md §4), and it works whether or
/// not decoder-level biasing ever does — it's a string substitution.
public final class CorrectionStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.torimi.murmur.corrections")

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try migrate()
        Self.restrictPermissions(at: url)
    }

    /// 0600. These files hold personal vocabulary and usage history; the default
    /// 0644 would let any other account on the Mac read them.
    private static func restrictPermissions(at url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// The default on-disk location.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/corrections.sqlite")
    }

    deinit { sqlite3_close(db) }

    public enum StoreError: LocalizedError {
        case open(String)
        case exec(String)

        public var errorDescription: String? {
            switch self {
            case .open(let m): "Could not open the corrections database: \(m)"
            case .exec(let m): "Corrections database error: \(m)"
            }
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS corrections (
          heard          TEXT NOT NULL,
          meant          TEXT NOT NULL,
          heard_key      TEXT NOT NULL,
          app_bundle_id  TEXT NOT NULL DEFAULT '',
          count          INTEGER NOT NULL DEFAULT 1,
          active         INTEGER NOT NULL DEFAULT 0,
          source         TEXT NOT NULL DEFAULT 'observed',
          first_seen     INTEGER NOT NULL,
          last_seen      INTEGER NOT NULL,
          PRIMARY KEY (heard, meant, app_bundle_id)
        );
        CREATE INDEX IF NOT EXISTS idx_active ON corrections(active, heard);
        """
        try exec(sql)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.exec(message)
        }
    }

    // MARK: - Learning

    /// Records a correction the user taught us directly. Applies immediately —
    /// there is no inferred path, so there is nothing to corroborate.
    public func learn(
        heard: String,
        meant: String,
        appBundleID: String? = nil
    ) throws {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard.lowercased() != meant.lowercased() else { return }

        try queue.sync {
            let now = Int(Date().timeIntervalSince1970)
            let sql = """
            INSERT INTO corrections (heard, meant, heard_key, app_bundle_id, count, active, first_seen, last_seen)
            VALUES (?, ?, ?, ?, 1, 1, ?, ?)
            ON CONFLICT(heard, meant, app_bundle_id) DO UPDATE SET
              count = count + 1,
              last_seen = excluded.last_seen,
              active = 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, heard, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, meant, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Phonetics.key(heard), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, appBundleID ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, Int64(now))
            sqlite3_bind_int64(stmt, 6, Int64(now))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Removes a pair. Every learned entry has to be reversible — a correction
    /// map you can't inspect or undo is a liability.
    public func forget(heard: String, meant: String, appBundleID: String? = nil) throws {
        try queue.sync {
            let sql = "DELETE FROM corrections WHERE heard = ? AND meant = ? AND app_bundle_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, heard, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, meant, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, appBundleID ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Reading

    /// Active corrections applicable to an app: global entries plus that app's own.
    public func active(for appBundleID: String? = nil) -> [Correction] {
        queue.sync {
            let sql = """
            SELECT heard, meant, app_bundle_id, count, active
            FROM corrections
            WHERE active = 1 AND (app_bundle_id = '' OR app_bundle_id = ?)
            ORDER BY LENGTH(heard) DESC;
            """
            return query(sql) { stmt in
                sqlite3_bind_text(stmt, 1, appBundleID ?? "", -1, SQLITE_TRANSIENT)
            }
        }
    }

    public func all() -> [Correction] {
        queue.sync {
            query("""
            SELECT heard, meant, app_bundle_id, count, active
            FROM corrections ORDER BY last_seen DESC;
            """) { _ in }
        }
    }

    /// Distinct target terms — what feeds the LLM cleanup prompt's vocabulary
    /// block, and the decoder hotword list if that ever starts working.
    public func vocabulary(for appBundleID: String? = nil) -> [String] {
        Array(Set(active(for: appBundleID).map(\.meant))).sorted()
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) -> [Correction] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var results: [Correction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = String(cString: sqlite3_column_text(stmt, 2))
            results.append(Correction(
                heard: String(cString: sqlite3_column_text(stmt, 0)),
                meant: String(cString: sqlite3_column_text(stmt, 1)),
                appBundleID: app.isEmpty ? nil : app,
                count: Int(sqlite3_column_int(stmt, 3)),
                active: sqlite3_column_int(stmt, 4) == 1
            ))
        }
        return results
    }
}
