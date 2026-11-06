import Foundation
import GRDB
import TrendingTabCore

public enum PersistenceError: Error {
    case migrationFailed(String)
    case invalidAIRun
    case invalidDocument
}

public enum AIRunReservation: Equatable, Sendable {
    case reserved, duplicateUnknown, budgetExhausted
}

public final class AppDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter
    private let fileManager: FileManager

    public init(path: String, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        writer = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    public static func live(fileManager: FileManager = .default) throws -> AppDatabase {
        let directory = TrendingPaths.supportDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("trendingtab.sqlite").path, fileManager: fileManager)
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try database.create(table: "items") { table in
                table.primaryKey("id", .text)
                table.column("payload", .text).notNull()
                table.column("first_seen_at", .datetime).notNull()
                table.column("last_seen_at", .datetime).notNull()
                table.column("content_hash", .text).notNull()
                table.column("historical", .boolean).notNull().defaults(to: false)
            }
            try database.create(table: "observations") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                table.column("board_id", .text).notNull()
                table.column("rank", .integer)
                table.column("metric", .double)
                table.column("fetched_at", .datetime).notNull()
            }
            try database.create(table: "events") { table in
                table.primaryKey("id", .text)
                table.column("payload", .text).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(table: "documents") { table in
                table.primaryKey("key", .text)
                table.column("payload", .text).notNull()
            }
            try database.create(table: "ai_runs") { table in
                table.primaryKey("id", .text)
                table.column("state", .text).notNull()
                table.column("reserved_tokens", .integer).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("payload", .text).notNull()
            }
            try database.create(table: "notifications") { table in
                table.primaryKey("operation_id", .text)
                table.column("event_id", .text).notNull()
                table.column("fingerprint", .text).notNull()
                table.column("state", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try database.create(table: "source_status") { table in
                table.primaryKey("id", .text)
                table.column("payload", .text).notNull()
            }
        }
        migrator.registerMigration("v2_ai_task_identity") { database in
            try database.alter(table: "ai_runs") { table in
                table.add(column: "task_key", .text)
            }
            try database.create(index: "ai_runs_task_state", on: "ai_runs", columns: ["task_key", "state"])
        }
        try migrator.migrate(writer)
    }

    public func save(result: FetchResult) throws {
        try writer.write { database in
            let incomingIDs = Set(result.items.map(\.id))
            for row in try Row.fetchAll(database, sql: "SELECT id, payload FROM items") {
                guard let id: String = row["id"], let payload: String = row["payload"],
                      let stored = try? TrendingJSON.value(StoredItem.self, from: Data(payload.utf8)),
                      stored.item.boardID == result.boardID, !incomingIDs.contains(id) else { continue }
                try database.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }
            try database.execute(sql: "DELETE FROM observations WHERE board_id = ?", arguments: [result.boardID])
            for entry in result.items {
                let existing = try Row.fetchOne(database, sql: "SELECT payload, first_seen_at, content_hash FROM items WHERE id = ?", arguments: [entry.id])
                let previous = existing.flatMap { row -> StoredItem? in
                    guard let payload: String = row["payload"], let data = payload.data(using: .utf8) else { return nil }
                    return try? TrendingJSON.value(StoredItem.self, from: data)
                }
                let hash = "\(entry.title)|\(entry.summary ?? "")".sha256Prefix
                let stored = StoredItem(
                    item: NormalizedItem(
                        sourceID: entry.sourceID, boardID: entry.boardID, nativeID: entry.nativeID, title: entry.title,
                        url: entry.url, summary: entry.summary, author: entry.author, publishedAt: entry.publishedAt,
                        rank: entry.rank, rawMetric: entry.rawMetric, metricLabel: entry.metricLabel
                    ),
                    firstSeenAt: previous?.firstSeenAt ?? result.fetchedAt,
                    lastSeenAt: result.fetchedAt,
                    previousRank: previous?.item.rank,
                    contentHash: hash,
                    historical: false
                )
                let payload = String(data: try TrendingJSON.data(stored), encoding: .utf8)!
                try database.execute(
                    sql: "INSERT INTO items (id, payload, first_seen_at, last_seen_at, content_hash, historical) VALUES (?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, last_seen_at = excluded.last_seen_at, content_hash = excluded.content_hash, historical = 0, first_seen_at = items.first_seen_at",
                    arguments: [entry.id, payload, stored.firstSeenAt, stored.lastSeenAt, hash]
                )
                try database.execute(
                    sql: "INSERT INTO observations (item_id, board_id, rank, metric, fetched_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [entry.id, entry.boardID, entry.rank, entry.rawMetric, result.fetchedAt]
                )
            }
        }
    }

    public func recentItems(since: Date) throws -> [StoredItem] {
        try writer.read { database in
            let rows = try Row.fetchAll(database,
                                       sql: "SELECT payload FROM items WHERE historical = 0 AND last_seen_at >= ? ORDER BY last_seen_at DESC",
                                       arguments: [since])
            return rows.compactMap { row in
                guard let payload: String = row["payload"] else { return nil }
                return try? TrendingJSON.value(StoredItem.self, from: Data(payload.utf8))
            }
        }
    }

    public func clear(boards: [String]) throws {
        let unique = Array(Set(boards))
        guard !unique.isEmpty else { return }
        try writer.write { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id, payload FROM items")
            for row in rows {
                guard let id: String = row["id"],
                      let payload: String = row["payload"],
                      let data = payload.data(using: .utf8),
                      let stored = try? TrendingJSON.value(StoredItem.self, from: data),
                      unique.contains(stored.item.boardID) else {
                    continue
                }
                try database.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }
        }
    }

    public func clear(boardsNotIn boards: Set<String>) throws {
        try writer.write { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id, payload FROM items")
            for row in rows {
                guard let id: String = row["id"],
                      let payload: String = row["payload"],
                      let data = payload.data(using: .utf8),
                      let stored = try? TrendingJSON.value(StoredItem.self, from: data),
                      !boards.contains(stored.item.boardID) else {
                    continue
                }
                try database.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }
        }
    }

    public func save(statuses: [SourceStatus]) throws {
        try writer.write { database in
            for status in statuses {
                try database.execute(
                    sql: "INSERT INTO source_status (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                    arguments: [status.id, String(data: try TrendingJSON.data(status), encoding: .utf8)!]
                )
            }
        }
    }

    public func statuses() throws -> [SourceStatus] {
        try writer.read { database in
            try Row.fetchAll(database, sql: "SELECT payload FROM source_status").compactMap { row in
                guard let payload: String = row["payload"] else { return nil }
                return try? TrendingJSON.value(SourceStatus.self, from: Data(payload.utf8))
            }
        }
    }

    public func document<T: Codable>(_ type: T.Type, key: String) throws -> T? {
        try writer.read { database in
            guard let payload = try String.fetchOne(database, sql: "SELECT payload FROM documents WHERE key = ?", arguments: [key]) else { return nil }
            return try TrendingJSON.value(type, from: Data(payload.utf8))
        }
    }

    public func saveDocument<T: Encodable>(_ value: T, key: String) throws {
        let payload = String(data: try TrendingJSON.data(value), encoding: .utf8)!
        try writer.write { database in
            try database.execute(sql: "INSERT INTO documents (key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload = excluded.payload", arguments: [key, payload])
        }
    }

    public func events() throws -> [EventCluster] {
        try writer.read { database in
            try Row.fetchAll(database, sql: "SELECT payload FROM events ORDER BY updated_at DESC").compactMap { row in
                guard let payload: String = row["payload"] else { return nil }
                return try? TrendingJSON.value(EventCluster.self, from: Data(payload.utf8))
            }
        }
    }

    public func save(events: [EventCluster]) throws {
        try writer.write { database in
            try Self.replaceEvents(events, in: database)
        }
    }

    private static func replaceEvents(_ events: [EventCluster], in database: Database) throws {
        try database.execute(sql: "DELETE FROM events")
        for event in events {
            try database.execute(sql: "INSERT INTO events (id, payload, updated_at) VALUES (?, ?, ?)",
                arguments: [event.id.uuidString, String(data: try TrendingJSON.data(event), encoding: .utf8)!, event.updatedAt])
        }
    }

    public func reserveAIRun(id: UUID, tokens: Int, now: Date) throws -> Bool {
        try reserveAIRun(id: id, tokens: tokens, now: now, taskKey: nil) == .reserved
    }

    public func reserveAIRun(id: UUID, tokens: Int, now: Date, taskKey: String?) throws -> AIRunReservation {
        try writer.write { database in
            let dayStart = Calendar.current.startOfDay(for: now)
            guard tokens > 0, let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return .budgetExhausted }
            if let taskKey {
                let existing = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ai_runs WHERE task_key = ? AND state IN ('reserved', 'unknown-accounted')", arguments: [taskKey]) ?? 0
                guard existing == 0 else { return .duplicateUnknown }
            }
            let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ai_runs WHERE created_at >= ? AND created_at < ?", arguments: [dayStart, dayEnd]) ?? 0
            let used = try Int.fetchOne(database, sql: "SELECT COALESCE(SUM(reserved_tokens), 0) FROM ai_runs WHERE created_at >= ? AND created_at < ?", arguments: [dayStart, dayEnd]) ?? 0
            let settings = (try String.fetchOne(database, sql: "SELECT payload FROM documents WHERE key = ?", arguments: ["settings"])).flatMap { try? TrendingJSON.value(AppSettings.self, from: Data($0.utf8)) } ?? .standard
            guard count < settings.dailyRequestLimit, used <= settings.dailyTokenLimit,
                  tokens <= settings.dailyTokenLimit - used else { return .budgetExhausted }
            let payload = "{\"state\":\"reserved\"}"
            try database.execute(sql: "INSERT INTO ai_runs (id, state, reserved_tokens, created_at, payload, task_key) VALUES (?, 'reserved', ?, ?, ?, ?)", arguments: [id.uuidString, tokens, now, payload, taskKey])
            return .reserved
        }
    }

    public func finishAIRun(id: UUID, state: String, actualTokens: Int? = nil) throws {
        try writer.write { database in
            try database.execute(sql: "UPDATE ai_runs SET state = ?, reserved_tokens = COALESCE(?, reserved_tokens) WHERE id = ? AND state = 'reserved'",
                                 arguments: [state, actualTokens.map { max(0, $0) }, id.uuidString])
        }
    }

    /// Results and their accounting become visible in the same SQLite transaction.
    public func completeAIRun(id: UUID, state: String, actualTokens: Int, events: [EventCluster]? = nil,
                              documentKey: String? = nil, documentPayload: Data? = nil) throws {
        guard state == "completed" || state == "completed-estimated",
              (documentKey == nil) == (documentPayload == nil) else { throw PersistenceError.invalidAIRun }
        let payload = documentPayload.flatMap { String(data: $0, encoding: .utf8) }
        guard documentPayload == nil || payload != nil else { throw PersistenceError.invalidAIRun }
        try writer.write { database in
            if let events { try Self.replaceEvents(events, in: database) }
            if let documentKey, let payload {
                try database.execute(sql: "INSERT INTO documents (key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload = excluded.payload", arguments: [documentKey, payload])
            }
            try database.execute(sql: "UPDATE ai_runs SET state = ?, reserved_tokens = ? WHERE id = ? AND state = 'reserved'",
                                 arguments: [state, max(0, actualTokens), id.uuidString])
            guard database.changesCount == 1 else { throw PersistenceError.invalidAIRun }
        }
    }

    public func recoverUnknownAIRuns() throws -> Int {
        try writer.write { database in
            try database.execute(sql: "UPDATE ai_runs SET state = 'unknown-accounted' WHERE state = 'reserved'")
            return database.changesCount
        }
    }

    public func unknownAIRunCount() throws -> Int {
        try writer.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ai_runs WHERE state = 'unknown-accounted' AND task_key IS NOT NULL") ?? 0
        }
    }

    /// Keeps the original charge, but permits a user-requested new attempt.
    public func acknowledgeUnknownAIRuns() throws -> Int {
        try writer.write { database in
            try database.execute(sql: "UPDATE ai_runs SET state = 'unknown-reviewed' WHERE state = 'unknown-accounted' AND task_key IS NOT NULL")
            return database.changesCount
        }
    }

    public func notificationExists(eventID: UUID, fingerprint: String, since: Date) throws -> Bool {
        try writer.read { database in
            let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM notifications WHERE event_id = ? AND fingerprint = ? AND created_at >= ? AND state IN ('sent', 'unknown')", arguments: [eventID.uuidString, fingerprint, since]) ?? 0
            return count > 0
        }
    }

    public func recordNotification(operationID: UUID, eventID: UUID, fingerprint: String, state: String, now: Date) throws {
        try writer.write { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO notifications (operation_id, event_id, fingerprint, state, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [operationID.uuidString, eventID.uuidString, fingerprint, state, now]
            )
        }
    }

    public func notifications(since: Date) throws -> Int {
        try writer.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM notifications WHERE created_at >= ? AND state IN ('sent', 'unknown')", arguments: [since]) ?? 0
        }
    }

    public func prune(now: Date, itemCutoff: Date? = nil, events: [EventCluster]? = nil, documents: [String: Data] = [:]) throws {
        let observationsCutoff = now.addingTimeInterval(-24 * 3600)
        let notificationsCutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let staleItemsCutoff = itemCutoff ?? now.addingTimeInterval(-24 * 3600)
        let payloads = try documents.mapValues { data -> String in
            guard let value = String(data: data, encoding: .utf8) else { throw PersistenceError.invalidDocument }
            return value
        }
        try writer.write { database in
            try database.execute(
                sql: "DELETE FROM items WHERE historical = 1 OR last_seen_at < ?",
                arguments: [staleItemsCutoff]
            )
            try database.execute(sql: "DELETE FROM observations WHERE fetched_at < ?", arguments: [observationsCutoff])
            try database.execute(sql: "DELETE FROM notifications WHERE created_at < ?", arguments: [notificationsCutoff])
            if let events { try Self.replaceEvents(events, in: database) }
            for (key, value) in payloads {
                try database.execute(sql: "INSERT INTO documents (key, payload) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload = excluded.payload", arguments: [key, value])
            }
        }
    }
}
