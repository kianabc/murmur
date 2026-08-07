import Foundation
import MurmurCore
import SQLite3

private let SQLITE_TRANSIENT_USAGE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One cleanup request.
public struct UsageEvent: Sendable {
    public let provider: String
    public let model: String
    /// Prompt tokens billed at full rate — the API's `input_tokens`, which is
    /// the *uncached remainder*, not the whole prompt.
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheWriteTokens: Int
    public let cacheReadTokens: Int
    /// Prices in dollars per million tokens, snapshotted at the time of the call.
    public let priceInPerMTok: Double
    public let priceOutPerMTok: Double
    public let latencyMs: Int
    public let guardFired: Bool
    public let wordCount: Int
    public let appBundleID: String?

    public init(
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        priceInPerMTok: Double,
        priceOutPerMTok: Double,
        latencyMs: Int,
        guardFired: Bool,
        wordCount: Int,
        appBundleID: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.priceInPerMTok = priceInPerMTok
        self.priceOutPerMTok = priceOutPerMTok
        self.latencyMs = latencyMs
        self.guardFired = guardFired
        self.wordCount = wordCount
        self.appBundleID = appBundleID
    }

    /// Cache writes bill at ~1.25× the input rate and reads at ~0.1×.
    public var costUSD: Double {
        let million = 1_000_000.0
        return Double(inputTokens) / million * priceInPerMTok
            + Double(cacheWriteTokens) / million * priceInPerMTok * 1.25
            + Double(cacheReadTokens) / million * priceInPerMTok * 0.1
            + Double(outputTokens) / million * priceOutPerMTok
    }
}

public struct UsageSummary: Sendable {
    public let dictations: Int
    /// Everything sent, including cached prompt tokens.
    public let sentTokens: Int
    public let receivedTokens: Int
    public let costUSD: Double
    public let words: Int
    public let guardRejections: Int
    public let averageLatencyMs: Int

    public static let empty = UsageSummary(
        dictations: 0, sentTokens: 0, receivedTokens: 0,
        costUSD: 0, words: 0, guardRejections: 0, averageLatencyMs: 0
    )

    /// The figure people actually have intuition for.
    public var costPerThousandWords: Double {
        guard words > 0 else { return 0 }
        return costUSD / Double(words) * 1000
    }
}

public struct ModelUsage: Sendable, Identifiable {
    public let model: String
    public let summary: UsageSummary
    public var id: String { model }
}

/// Spend for one vendor. Kept apart because each bills you separately — a
/// combined figure can't be reconciled against either invoice.
public struct ProviderUsage: Sendable, Identifiable {
    public let provider: String
    public let summary: UsageSummary
    public var id: String { provider }
}

/// Append-only log of cleanup requests.
///
/// Rows are immutable and carry their own prices, so changing the price table
/// later can never rewrite what past months cost (SPEC.md §7). The model is just
/// a column, which is why switching models loses no history.
public final class UsageStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.torimi.murmur.usage")

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw StoreFailure.open(String(cString: sqlite3_errmsg(db)))
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

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/usage.sqlite")
    }

    deinit { sqlite3_close(db) }

    public enum StoreFailure: LocalizedError {
        case open(String)
        case exec(String)

        public var errorDescription: String? {
            switch self {
            case .open(let m): "Could not open the usage database: \(m)"
            case .exec(let m): "Usage database error: \(m)"
            }
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage (
          id                  TEXT PRIMARY KEY,
          ts                  INTEGER NOT NULL,
          app_bundle_id       TEXT,
          provider            TEXT NOT NULL DEFAULT 'anthropic',
          model               TEXT NOT NULL,
          input_tokens        INTEGER NOT NULL,
          output_tokens       INTEGER NOT NULL,
          cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
          price_in_per_mtok   REAL NOT NULL,
          price_out_per_mtok  REAL NOT NULL,
          cost_usd            REAL NOT NULL,
          latency_ms          INTEGER NOT NULL,
          guard_fired         INTEGER NOT NULL,
          word_count          INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts);
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreFailure.exec(message)
        }
        addProviderColumnIfMissing()
    }

    /// 1.0.0 shipped without a provider column. Existing rows predate multiple
    /// providers, so they were all Anthropic.
    private func addProviderColumnIfMissing() {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(usage);", -1, &stmt, nil) == SQLITE_OK else { return }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == "provider" { found = true }
        }
        sqlite3_finalize(stmt)
        guard !found else { return }
        sqlite3_exec(db, "ALTER TABLE usage ADD COLUMN provider TEXT NOT NULL DEFAULT 'anthropic';", nil, nil, nil)
    }

    // MARK: - Recording

    public func record(_ event: UsageEvent, at date: Date = Date()) {
        var wrote = false
        queue.sync {
            let sql = """
            INSERT INTO usage (
              id, ts, app_bundle_id, provider, model,
              input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
              price_in_per_mtok, price_out_per_mtok, cost_usd,
              latency_ms, guard_fired, word_count
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT_USAGE)
            sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
            sqlite3_bind_text(stmt, 3, event.appBundleID ?? "", -1, SQLITE_TRANSIENT_USAGE)
            sqlite3_bind_text(stmt, 4, event.provider, -1, SQLITE_TRANSIENT_USAGE)
            sqlite3_bind_text(stmt, 5, event.model, -1, SQLITE_TRANSIENT_USAGE)
            sqlite3_bind_int(stmt, 6, Int32(event.inputTokens))
            sqlite3_bind_int(stmt, 7, Int32(event.outputTokens))
            sqlite3_bind_int(stmt, 8, Int32(event.cacheWriteTokens))
            sqlite3_bind_int(stmt, 9, Int32(event.cacheReadTokens))
            sqlite3_bind_double(stmt, 10, event.priceInPerMTok)
            sqlite3_bind_double(stmt, 11, event.priceOutPerMTok)
            // Resolved now, never recomputed — see the type doc.
            sqlite3_bind_double(stmt, 12, event.costUSD)
            sqlite3_bind_int(stmt, 13, Int32(event.latencyMs))
            sqlite3_bind_int(stmt, 14, event.guardFired ? 1 : 0)
            sqlite3_bind_int(stmt, 15, Int32(event.wordCount))

            let status = sqlite3_step(stmt)
            if status != SQLITE_DONE {
                Log.echo("usage: WRITE FAILED (\(status)) — \(String(cString: sqlite3_errmsg(db)))")
            }
            wrote = status == SQLITE_DONE
        }

        // Posted *outside* queue.sync, and hopped to main. An observer that
        // reads the store — which is exactly what the settings window does —
        // would otherwise re-enter queue.sync on the queue's own thread, and
        // dispatch traps on that.
        guard wrote else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .murmurUsageRecorded, object: nil)
        }
    }

    // MARK: - Reading

    /// Pass `nil` for all time.
    public func summary(since: Date?) -> UsageSummary {
        queue.sync {
            let sql = """
            SELECT COUNT(*),
                   COALESCE(SUM(input_tokens + cache_write_tokens + cache_read_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(SUM(word_count), 0),
                   COALESCE(SUM(guard_fired), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM usage
            WHERE (?1 = 0 OR ts >= ?1);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .empty }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(since?.timeIntervalSince1970 ?? 0))

            guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }
            return UsageSummary(
                dictations: Int(sqlite3_column_int(stmt, 0)),
                sentTokens: Int(sqlite3_column_int64(stmt, 1)),
                receivedTokens: Int(sqlite3_column_int64(stmt, 2)),
                costUSD: sqlite3_column_double(stmt, 3),
                words: Int(sqlite3_column_int64(stmt, 4)),
                guardRejections: Int(sqlite3_column_int(stmt, 5)),
                averageLatencyMs: Int(sqlite3_column_double(stmt, 6))
            )
        }
    }

    /// Spend split by vendor, so each can be checked against its own invoice.
    public func byProvider(since: Date?) -> [ProviderUsage] {
        queue.sync {
            let sql = """
            SELECT provider, COUNT(*),
                   COALESCE(SUM(input_tokens + cache_write_tokens + cache_read_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(SUM(word_count), 0),
                   COALESCE(SUM(guard_fired), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM usage
            WHERE (?1 = 0 OR ts >= ?1)
            GROUP BY provider
            ORDER BY SUM(cost_usd) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(since?.timeIntervalSince1970 ?? 0))

            var rows: [ProviderUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ProviderUsage(
                    provider: String(cString: sqlite3_column_text(stmt, 0)),
                    summary: UsageSummary(
                        dictations: Int(sqlite3_column_int(stmt, 1)),
                        sentTokens: Int(sqlite3_column_int64(stmt, 2)),
                        receivedTokens: Int(sqlite3_column_int64(stmt, 3)),
                        costUSD: sqlite3_column_double(stmt, 4),
                        words: Int(sqlite3_column_int64(stmt, 5)),
                        guardRejections: Int(sqlite3_column_int(stmt, 6)),
                        averageLatencyMs: Int(sqlite3_column_double(stmt, 7))
                    )
                ))
            }
            return rows
        }
    }

    public func byModel(since: Date?) -> [ModelUsage] {
        queue.sync {
            let sql = """
            SELECT model, COUNT(*),
                   COALESCE(SUM(input_tokens + cache_write_tokens + cache_read_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(SUM(word_count), 0),
                   COALESCE(SUM(guard_fired), 0),
                   COALESCE(AVG(latency_ms), 0)
            FROM usage
            WHERE (?1 = 0 OR ts >= ?1)
            GROUP BY model
            ORDER BY SUM(cost_usd) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(since?.timeIntervalSince1970 ?? 0))

            var rows: [ModelUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ModelUsage(
                    model: String(cString: sqlite3_column_text(stmt, 0)),
                    summary: UsageSummary(
                        dictations: Int(sqlite3_column_int(stmt, 1)),
                        sentTokens: Int(sqlite3_column_int64(stmt, 2)),
                        receivedTokens: Int(sqlite3_column_int64(stmt, 3)),
                        costUSD: sqlite3_column_double(stmt, 4),
                        words: Int(sqlite3_column_int64(stmt, 5)),
                        guardRejections: Int(sqlite3_column_int(stmt, 6)),
                        averageLatencyMs: Int(sqlite3_column_double(stmt, 7))
                    )
                ))
            }
            return rows
        }
    }

    /// When the first request was logged, so the all-time column can say since when.
    public func firstRecordedAt() -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM usage;", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
        }
    }
}
