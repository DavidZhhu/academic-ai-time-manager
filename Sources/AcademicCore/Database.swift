import CSQLite
import Foundation

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    public var errorDescription: String? {
        switch self { case .open(let message), .execute(let message), .prepare(let message): return message }
    }
}

public final class LocalDatabase {
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String = ":memory:") throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK, handle != nil else {
            throw DatabaseError.open("Could not open local database")
        }
        try migrate()
    }

    deinit { sqlite3_close(handle) }

    public func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS source_records (id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_id TEXT NOT NULL, retrieved_at TEXT NOT NULL, payload_json TEXT NOT NULL, UNIQUE(provider, external_id));")
        try execute("CREATE TABLE IF NOT EXISTS academic_items (id TEXT PRIMARY KEY, starts_at TEXT NOT NULL, ends_at TEXT NOT NULL, timezone TEXT NOT NULL, verification TEXT NOT NULL, payload_json TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS review_items (id TEXT PRIMARY KEY, state TEXT NOT NULL, payload_json TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, payload_json TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY, state TEXT NOT NULL, payload_json TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, decision TEXT NOT NULL, payload_json TEXT NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS audit_entries (id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, payload_json TEXT NOT NULL);")
        try execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, datetime('now'));")
        try execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (2, datetime('now'));")
        try execute("CREATE TABLE IF NOT EXISTS assignment_progress (assignment_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL);")
        try execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (3, datetime('now'));")
    }

    public func save(_ record: SourceRecord) throws {
        let json = try encoded(record)
        try withStatement("INSERT INTO source_records(id, provider, external_id, retrieved_at, payload_json) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, external_id=excluded.external_id, retrieved_at=excluded.retrieved_at, payload_json=excluded.payload_json;") { statement in
            bind(record.id, to: 1, in: statement); bind(record.provider, to: 2, in: statement); bind(record.externalID, to: 3, in: statement)
            bind(ISO8601DateFormatter().string(from: record.retrievedAt), to: 4, in: statement); bind(json, to: 5, in: statement)
        }
    }

    public func importCanvas(_ result: CanvasImportResult, successfulAt: Date? = nil) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            for source in result.sourceRecords { try save(source) }
            for item in result.academicItems { try save(item) }
            if let successfulAt {
                let json = try encoded(successfulAt)
                try withStatement("INSERT INTO app_settings(key, payload_json) VALUES ('canvas_last_successful_sync', ?) ON CONFLICT(key) DO UPDATE SET payload_json=excluded.payload_json;") { bind(json, to: 1, in: $0) }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func sourceRecords() throws -> [SourceRecord] { try readJSON("SELECT payload_json FROM source_records ORDER BY id;") }
    public func sourceRecordCount() throws -> Int { try scalarInt("SELECT COUNT(*) FROM source_records;") }
    public func migrationCount() throws -> Int { try scalarInt("SELECT COUNT(*) FROM schema_migrations;") }

    public func save(_ item: AcademicItem) throws {
        let json = try encoded(item)
        try withStatement("INSERT INTO academic_items(id, starts_at, ends_at, timezone, verification, payload_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET starts_at=excluded.starts_at, ends_at=excluded.ends_at, timezone=excluded.timezone, verification=excluded.verification, payload_json=excluded.payload_json;") { statement in
            bind(item.id, to: 1, in: statement); bind(ISO8601DateFormatter().string(from: item.startsAt), to: 2, in: statement)
            bind(ISO8601DateFormatter().string(from: item.endsAt), to: 3, in: statement); bind(item.timeZoneIdentifier, to: 4, in: statement)
            bind(item.verification.rawValue, to: 5, in: statement); bind(json, to: 6, in: statement)
        }
    }

    public func items() throws -> [AcademicItem] {
        try readJSON("SELECT payload_json FROM academic_items ORDER BY starts_at;")
    }

    public func save(_ item: ReviewItem) throws {
        let json = try encoded(item)
        try withStatement("INSERT INTO review_items(id, state, payload_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET state=excluded.state, payload_json=excluded.payload_json;") { statement in
            bind(item.id, to: 1, in: statement); bind(item.state.rawValue, to: 2, in: statement); bind(json, to: 3, in: statement)
        }
    }

    public func reviewItems() throws -> [ReviewItem] { try readJSON("SELECT payload_json FROM review_items ORDER BY id;") }

    public func save(_ conflict: AcademicConflict) throws {
        let json = try encoded(conflict)
        try withStatement("INSERT INTO conflicts(id, state, payload_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET state=excluded.state, payload_json=excluded.payload_json;") { statement in
            bind(conflict.id, to: 1, in: statement); bind(conflict.state.rawValue, to: 2, in: statement); bind(json, to: 3, in: statement)
        }
    }

    public func conflicts() throws -> [AcademicConflict] { try readJSON("SELECT payload_json FROM conflicts ORDER BY id;") }

    public func save(_ approval: ChangeApproval) throws {
        let json = try encoded(approval)
        try withStatement("INSERT INTO approvals(id, decision, payload_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET decision=excluded.decision, payload_json=excluded.payload_json;") { statement in
            bind(approval.id, to: 1, in: statement); bind(approval.decision.rawValue, to: 2, in: statement); bind(json, to: 3, in: statement)
        }
    }

    public func approvals() throws -> [ChangeApproval] { try readJSON("SELECT payload_json FROM approvals ORDER BY id;") }

    public func append(_ entry: AuditEntry) throws {
        let json = try encoded(entry)
        try withStatement("INSERT OR IGNORE INTO audit_entries(id, timestamp, payload_json) VALUES (?, ?, ?);") { statement in
            bind(entry.id, to: 1, in: statement); bind(ISO8601DateFormatter().string(from: entry.timestamp), to: 2, in: statement); bind(json, to: 3, in: statement)
        }
    }

    public func auditEntries() throws -> [AuditEntry] { try readJSON("SELECT payload_json FROM audit_entries ORDER BY timestamp, id;") }

    public func save(_ settings: AvailabilitySettings) throws {
        let json = try encoded(settings)
        try withStatement("INSERT INTO app_settings(key, payload_json) VALUES ('availability', ?) ON CONFLICT(key) DO UPDATE SET payload_json=excluded.payload_json;") { statement in bind(json, to: 1, in: statement) }
    }

    public func availabilitySettings() throws -> AvailabilitySettings? {
        try readJSON("SELECT payload_json FROM app_settings WHERE key = 'availability';").first
    }

    public func lastSuccessfulCanvasSync() throws -> Date? {
        try readJSON("SELECT payload_json FROM app_settings WHERE key = 'canvas_last_successful_sync';").first
    }

    public func save(_ progress: AssignmentProgress) throws {
        let json = try encoded(progress)
        try withStatement("INSERT INTO assignment_progress(assignment_id, payload_json) VALUES (?, ?) ON CONFLICT(assignment_id) DO UPDATE SET payload_json=excluded.payload_json;") { statement in
            bind(progress.assignmentID, to: 1, in: statement); bind(json, to: 2, in: statement)
        }
    }

    public func assignmentProgress() throws -> [String: AssignmentProgress] {
        let values: [AssignmentProgress] = try readJSON("SELECT payload_json FROM assignment_progress ORDER BY assignment_id;")
        return Dictionary(uniqueKeysWithValues: values.map { ($0.assignmentID, $0) })
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message); throw DatabaseError.execute(detail)
        }
    }

    private func withStatement(_ sql: String, bindValues: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.prepare("Could not prepare database statement") }
        defer { sqlite3_finalize(statement) }
        bindValues(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle))) }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.prepare("Could not prepare count query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.execute("Could not read count") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func readJSON<T: Decodable>(_ sql: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.prepare("Could not prepare read query") }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            values.append(try decoder.decode(T.self, from: Data(String(cString: raw).utf8)))
        }
        return values
    }
}
