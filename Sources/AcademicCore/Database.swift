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

    /// Milliseconds a connection waits for another connection's lock before reporting SQLITE_BUSY.
    public let busyTimeoutMilliseconds: Int32
    /// The journal mode SQLite reports after opening ("wal" when write-ahead logging is active).
    public private(set) var journalMode = ""

    /// - Parameters:
    ///   - busyTimeoutMilliseconds: Lock wait before a read or write fails with a `DatabaseError`.
    ///   - enableWAL: Requests write-ahead logging. If the store or filesystem cannot switch, the
    ///     existing journal mode is kept and the database remains usable. Schemas and rows are untouched.
    public init(path: String = ":memory:", busyTimeoutMilliseconds: Int32 = 5_000, enableWAL: Bool = true) throws {
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        guard sqlite3_open(path, &handle) == SQLITE_OK, handle != nil else {
            throw DatabaseError.open("Could not open local database")
        }
        // Must precede every other statement so setup and migration also wait instead of failing at once.
        guard sqlite3_busy_timeout(handle, self.busyTimeoutMilliseconds) == SQLITE_OK else {
            throw DatabaseError.open("Could not configure local database")
        }
        // An in-memory database reports "memory" and ignores the request; a failed switch is not fatal.
        if enableWAL { _ = singleText("PRAGMA journal_mode=WAL;") }
        journalMode = singleText("PRAGMA journal_mode;") ?? ""
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
        let values: [AvailabilitySettings] = try readJSON("SELECT payload_json FROM app_settings WHERE key = 'availability';")
        return values.first
    }

    /// Returns saved availability, or stores and returns `defaultSettings` only when no row exists.
    /// A failed or undecodable read throws and never reaches the write, so saved preferences are not replaced.
    public func loadOrCreateAvailabilitySettings(default defaultSettings: AvailabilitySettings = AvailabilitySettings()) throws -> AvailabilitySettings {
        if let saved = try availabilitySettings() { return saved }
        try save(defaultSettings)
        return defaultSettings
    }

    public func lastSuccessfulCanvasSync() throws -> Date? {
        let values: [Date] = try readJSON("SELECT payload_json FROM app_settings WHERE key = 'canvas_last_successful_sync';")
        return values.first
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

    public func outlookState() throws -> OutlookState {
        let values: [OutlookState] = try readJSON("SELECT payload_json FROM app_settings WHERE key = 'outlook_state';")
        return values.first ?? OutlookState()
    }

    public func save(_ state: OutlookState) throws {
        let json = try encoded(state)
        try withStatement("INSERT INTO app_settings(key, payload_json) VALUES ('outlook_state', ?) ON CONFLICT(key) DO UPDATE SET payload_json=excluded.payload_json;") { bind(json, to: 1, in: $0) }
    }

    /// Checkpoint, message revisions, source provenance and review changes commit atomically.
    public func importOutlook(_ batch: OutlookSyncBatch) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            var state = try outlookState()
            guard let index = state.accounts.firstIndex(where: { $0.id == batch.account.id && $0.connected }) else { throw OutlookError.reconnect }
            state.accounts[index] = batch.account
            let updatedMessages = Set(batch.messages.values.map(\.messageID))
            let incomingIDs = Set(batch.proposals.map(\.id))
            for i in state.proposals.indices where state.proposals[i].accountID == batch.account.id {
                let old = state.proposals[i]
                if batch.removedMessageIDs.contains(old.messageID) || (updatedMessages.contains(old.messageID) && !incomingIDs.contains(old.id)) {
                    state.proposals[i].withdrawn = true
                    state.proposals[i].note = "Source email was changed, moved, or removed. Previously approved commitments are preserved; check them manually."
                }
            }
            for proposal in batch.proposals {
                if let i = state.proposals.firstIndex(where: { $0.id == proposal.id }) {
                    // The ID hashes the extracted source facts, not user-edited dates/durations.
                    // Re-fetching unchanged evidence must preserve local corrections and decisions.
                    if state.proposals[i].withdrawn { state.proposals[i].note = proposal.note }
                    state.proposals[i].withdrawn = false
                } else { state.proposals.append(proposal) }
            }
            state.messages.merge(batch.messages) { _, new in new }
            for source in batch.sources { try save(source) }
            state.proposals = EmailReviewRules.annotated(state.proposals, existing: AcademicDataset(items: try items(), sources: try sourceRecords()).items)
            try save(state)
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    /// One transaction for the entire batch; never invokes a mailbox or calendar API.
    public func decideOutlook(ids: Set<String>, decision: ReviewDecision) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            var state = try outlookState()
            let selected = state.proposals.filter { ids.contains($0.id) }
            guard !ids.isEmpty, selected.count == ids.count else { throw OutlookError.review }
            if decision == .accepted && selected.contains(where: { !$0.canApprove }) { throw OutlookError.review }
            var events = AcademicDataset(items: try items(), sources: try sourceRecords()).items
            for i in state.proposals.indices where ids.contains(state.proposals[i].id) {
                var proposal = state.proposals[i]
                // Rejecting a previously accepted event does not silently delete its protected commitment.
                guard proposal.decision == .pending else { throw OutlookError.review }
                proposal.decision = decision
                if decision == .accepted, !proposal.kind.advisory, let date = proposal.date {
                    let kind: AcademicItemKind = proposal.kind == .tutorial ? .tutorial : (proposal.kind == .deadline || proposal.kind == .task) ? .deadline : .classSession
                    let expectedEnd = kind == .deadline ? date : date.addingTimeInterval(TimeInterval(proposal.durationMinutes * 60))
                    let matching = events.firstIndex { $0.title.lowercased() == proposal.title.lowercased() && $0.kind == kind && $0.startsAt == date && $0.endsAt == expectedEnd }
                    if let matching {
                        if !events[matching].sourceRecordIDs.contains(proposal.sourceID) { events[matching].sourceRecordIDs.append(proposal.sourceID) }
                        try save(events[matching])
                    } else {
                        let event = AcademicItem(id: "outlook-event-" + proposal.fingerprint, title: proposal.title,
                            startsAt: date, endsAt: kind == .deadline ? date : date.addingTimeInterval(TimeInterval(proposal.durationMinutes * 60)),
                            timeZoneIdentifier: state.settings.timeZoneIdentifier, kind: kind, verification: .verified,
                            sourceRecordIDs: [proposal.sourceID], isProtected: true)
                        try save(event); events.append(event)
                    }
                }
                state.proposals[i] = proposal
                try append(AuditEntry(id: UUID().uuidString, actor: "user", action: "email-review-" + decision.rawValue,
                    targetID: proposal.id, beforeReference: "pending", afterReference: decision.rawValue, timestamp: Date()))
            }
            state.proposals = EmailReviewRules.annotated(state.proposals, existing: events)
            try save(state)
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
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

    /// First column of the first row of a pragma, or nil if the statement fails (for example while locked).
    private func singleText(_ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text).lowercased()
    }

    private func readJSON<T: Decodable>(_ sql: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.prepare("Could not prepare read query") }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            // SQLITE_BUSY, I/O and corruption errors must not look like the end of the table.
            guard result == SQLITE_ROW else { throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle))) }
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            values.append(try decoder.decode(T.self, from: Data(String(cString: raw).utf8)))
        }
        return values
    }
}
