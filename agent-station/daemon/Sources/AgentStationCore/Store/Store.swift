import Foundation
import GRDB

/// SQLite (WAL) via GRDB. The daemon owns state; the panel, menu bar, and
/// VS Code extension are all clients that can die and re-hydrate.
public final class Store: Sendable {
    public static let retentionEvents: TimeInterval = 30 * 86400
    public static let retentionUsage: TimeInterval = 396 * 86400  // 13mo, YoY works

    public enum StoreError: Error, Sendable {
        case migrationResourceMissing
    }

    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // WAL is set here, not inside the migration SQL: `PRAGMA journal_mode
        // = WAL` cannot run inside a transaction, and GRDB's DatabaseMigrator
        // wraps every registered migration in one. prepareDatabase runs once
        // per connection, before any transaction opens.
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: path.path, configuration: config)
        try Self.migrate(dbQueue)
    }

    /// In-memory store, for tests and previews.
    public static func inMemory() throws -> Store {
        try Store()
    }

    private init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrate(dbQueue)
    }

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001_init") { db in
            guard let url = Bundle.module.url(
                forResource: "001_init", withExtension: "sql", subdirectory: "migrations")
            else { throw StoreError.migrationResourceMissing }
            try db.execute(sql: try String(contentsOf: url, encoding: .utf8))
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Writes

    /// Persists a canonical event: upserts the owning session, records focus
    /// context once (write-once by design — see ARCHITECTURE.md §11), and
    /// appends the event row.
    public func record(_ event: CanonicalEvent) throws {
        try dbQueue.write { db in
            try Self.upsertSession(db, event: event)
            if let focus = event.focus {
                try Self.insertFocusOnce(db, sessionID: event.session.id, focus: focus, at: event.ts)
            }
            try Self.insertEvent(db, event: event)
        }
    }

    /// station doctor's regression net: a provider event nothing in the
    /// manifest matched. Visible, not silent — ARCHITECTURE.md §14.
    public func recordUnmapped(_ unmapped: Normalizer.UnmappedEvent) throws {
        let seenMS = Self.millis(unmapped.seenAt)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO unmapped_event (provider, provider_event, first_seen_at, last_seen_at, count, sample_json)
                VALUES (?, ?, ?, ?, 1, ?)
                ON CONFLICT(provider, provider_event) DO UPDATE SET
                    last_seen_at = excluded.last_seen_at,
                    count = unmapped_event.count + 1
                """, arguments: [
                    unmapped.provider.rawValue, unmapped.providerEvent ?? "(unknown)",
                    seenMS, seenMS, unmapped.sampleJSON,
                ])
        }
    }

    // MARK: - Reads

    public struct UnmappedEventRow: Sendable {
        public let provider: String
        public let providerEvent: String
        public let firstSeenAt: Date
        public let lastSeenAt: Date
        public let count: Int
    }

    public func unmappedEvents() throws -> [UnmappedEventRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, provider_event, first_seen_at, last_seen_at, count
                FROM unmapped_event ORDER BY last_seen_at DESC
                """)
            return rows.map {
                UnmappedEventRow(
                    provider: $0["provider"], providerEvent: $0["provider_event"],
                    firstSeenAt: Self.date(fromMillis: $0["first_seen_at"]),
                    lastSeenAt: Self.date(fromMillis: $0["last_seen_at"]),
                    count: $0["count"])
            }
        }
    }

    public struct EventRow: Sendable {
        public let sessionID: String
        public let kind: String
        public let providerEvent: String?
        public let ts: Date
        public let payloadJSON: String
    }

    /// Most recent events, newest first. `station tail --raw` and initial
    /// backfill for a freshly-connected subscriber both read from here.
    public func recentEvents(limit: Int = 50) throws -> [EventRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, kind, provider_event, ts, payload_json
                FROM event ORDER BY ts DESC LIMIT ?
                """, arguments: [limit])
            return rows.map {
                EventRow(
                    sessionID: $0["session_id"], kind: $0["kind"], providerEvent: $0["provider_event"],
                    ts: Self.date(fromMillis: $0["ts"]), payloadJSON: $0["payload_json"])
            }
        }
    }

    // MARK: - Private helpers

    private static func upsertSession(_ db: Database, event: CanonicalEvent) throws {
        let s = event.session
        let endedAtMS: Int? = (event.kind == .sessionEnded) ? millis(event.ts) : nil
        try db.execute(sql: """
            INSERT INTO session (id, provider, project_id, cwd, surface, model, started_at, ended_at, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ended_at = COALESCE(excluded.ended_at, session.ended_at),
                state    = excluded.state
            """, arguments: [
                s.id, event.provider.rawValue, s.projectID, s.cwd, s.surface.rawValue, s.model,
                millis(s.startedAt), endedAtMS, sessionState(for: event.kind),
            ])
    }

    private static func sessionState(for kind: EventKind) -> String {
        switch kind {
        case .sessionEnded: return "ended"
        case .errorRaised: return "error"
        default: return "active"
        }
    }

    /// PRIMARY KEY on session_id makes this write-once by construction — a
    /// second session.started-adjacent event for the same session cannot
    /// overwrite the focus context captured at the first one.
    private static func insertFocusOnce(_ db: Database, sessionID: String, focus: FocusContext, at ts: Date) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO focus_context
                (session_id, term_program, term_session_id, tmux_pane, host_pid, ide_window_id, workspace_uri, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                sessionID, focus.termProgram, focus.termSessionID ?? focus.itermSessionID,
                focus.tmuxPane, focus.hostPID, focus.ideWindowID, focus.workspaceURI, millis(ts),
            ])
    }

    private static func insertEvent(_ db: Database, event: CanonicalEvent) throws {
        let encoder = JSONEncoder()
        let payloadData = (try? encoder.encode(event.payload)) ?? Data("{}".utf8)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
        try db.execute(sql: """
            INSERT INTO event (session_id, kind, provider_event, ts, payload_json)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                event.session.id, event.kind.rawValue, event.providerEvent, millis(event.ts), payloadJSON,
            ])
    }

    private static func millis(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
    private static func date(fromMillis ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
