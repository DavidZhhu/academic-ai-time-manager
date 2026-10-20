import XCTest
import CSQLite
@testable import AcademicCore

/// Synthetic temporary databases only. No production database, account or Keychain record is opened.
final class SQLiteReliabilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appendingPathComponent("test.sqlite").path }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let customSettings = AvailabilitySettings(studyStartHour: 8, studyEndHour: 20, protectedRestStartHour: 23,
                                                      protectedRestEndHour: 7, timeZoneIdentifier: "Europe/London")

    private func item(_ id: String = "i1") -> AcademicItem {
        AcademicItem(id: id, title: "Lecture", startsAt: start, endsAt: start.addingTimeInterval(3600), timeZoneIdentifier: "Europe/London",
                     kind: .classSession, verification: .verified, sourceRecordIDs: ["s1"], isProtected: true)
    }

    /// A second connection used to hold locks or corrupt a fixture row.
    private func rawConnection() throws -> OpaquePointer {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        return try XCTUnwrap(handle)
    }

    private func exec(_ handle: OpaquePointer, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql, file: file, line: line)
    }

    private func storedAvailabilityPayload() throws -> String? {
        let handle = try rawConnection(); defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT payload_json FROM app_settings WHERE key = 'availability';", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    // MARK: readJSON

    func testReadReportsBusyInsteadOfReturningEmptyResults() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 50, enableWAL: false)
        try db.save(item()); try db.save(customSettings)
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN EXCLUSIVE;")

        XCTAssertThrowsError(try db.items()) { XCTAssertTrue($0 is DatabaseError) }
        XCTAssertThrowsError(try db.availabilitySettings())
        XCTAssertThrowsError(try db.outlookState(), "A failed read must not look like an empty Outlook state")

        exec(writer, "ROLLBACK;")
        XCTAssertEqual(try db.items(), [item()])
        XCTAssertEqual(try db.availabilitySettings(), customSettings)
    }

    func testCorruptPayloadIsReportedAndLeftUntouched() throws {
        let db = try LocalDatabase(path: path)
        try db.save(customSettings)
        let raw = try rawConnection(); defer { sqlite3_close(raw) }
        exec(raw, "UPDATE app_settings SET payload_json = '{not json' WHERE key = 'availability';")

        XCTAssertThrowsError(try db.availabilitySettings())
        XCTAssertEqual(try storedAvailabilityPayload(), "{not json", "Reading must never rewrite stored data")
    }

    // MARK: availability preservation

    func testLoadOrCreateReturnsSavedSettingsWithoutRewriting() throws {
        let db = try LocalDatabase(path: path)
        try db.save(customSettings)
        let before = try storedAvailabilityPayload()
        XCTAssertEqual(try db.loadOrCreateAvailabilitySettings(), customSettings)
        XCTAssertEqual(try storedAvailabilityPayload(), before)
    }

    func testLoadOrCreateSavesDefaultsOnlyWhenNothingIsStored() throws {
        let db = try LocalDatabase(path: path)
        XCTAssertNil(try db.availabilitySettings())
        let defaults = AvailabilitySettings(timeZoneIdentifier: "Europe/London")
        XCTAssertEqual(try db.loadOrCreateAvailabilitySettings(default: defaults), defaults)
        XCTAssertEqual(try db.availabilitySettings(), defaults)
    }

    func testLoadOrCreatePreservesSavedSettingsWhenReadFails() throws {
        let db = try LocalDatabase(path: path)
        try db.save(customSettings)
        let raw = try rawConnection(); defer { sqlite3_close(raw) }
        exec(raw, "UPDATE app_settings SET payload_json = '{not json' WHERE key = 'availability';")
        XCTAssertThrowsError(try db.loadOrCreateAvailabilitySettings())
        XCTAssertEqual(try storedAvailabilityPayload(), "{not json")
    }

    func testLoadOrCreatePreservesSavedSettingsWhenDatabaseIsBusy() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 50, enableWAL: false)
        try db.save(customSettings)
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN EXCLUSIVE;")
        XCTAssertThrowsError(try db.loadOrCreateAvailabilitySettings())
        exec(writer, "ROLLBACK;")
        XCTAssertEqual(try db.availabilitySettings(), customSettings)
    }

    // MARK: busy timeout

    func testBusyTimeoutIsConfigured() throws {
        XCTAssertEqual(try LocalDatabase(path: path).busyTimeoutMilliseconds, 5_000)
        XCTAssertEqual(try LocalDatabase(path: path, busyTimeoutMilliseconds: 250).busyTimeoutMilliseconds, 250)
        XCTAssertEqual(try LocalDatabase(path: path, busyTimeoutMilliseconds: -5).busyTimeoutMilliseconds, 0)
    }

    func testWriteWaitsForAnotherWriterAndThenSucceeds() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 5_000)
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN IMMEDIATE;")
        let released = expectation(description: "writer released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            sqlite3_exec(writer, "COMMIT;", nil, nil, nil); released.fulfill()
        }
        let started = Date()
        try db.save(item())
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.1, "The write should have waited for the lock")
        wait(for: [released], timeout: 5)
        XCTAssertEqual(try db.items(), [item()])
    }

    func testWriteReportsBusyAfterTimeoutWithoutLosingExistingData() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 50)
        try db.save(item("kept"))
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN IMMEDIATE;")
        let started = Date()
        XCTAssertThrowsError(try db.save(item("blocked"))) { XCTAssertTrue($0 is DatabaseError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        exec(writer, "ROLLBACK;")
        XCTAssertEqual(try db.items().map(\.id), ["kept"])
    }

    func testImportTransactionRollsBackWhenAnotherWriterHoldsTheLock() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 50)
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN IMMEDIATE;")
        let result = CanvasImportResult(sourceRecords: [SourceRecord(id: "s", provider: "Canvas", externalID: "e", retrievedAt: start)],
                                        academicItems: [item()])
        XCTAssertThrowsError(try db.importCanvas(result, successfulAt: start))
        exec(writer, "ROLLBACK;")
        XCTAssertEqual(try db.sourceRecordCount(), 0)
        XCTAssertNil(try db.lastSuccessfulCanvasSync())
        // The failed import must not leave a transaction open.
        try db.importCanvas(result, successfulAt: start)
        XCTAssertEqual(try db.sourceRecordCount(), 1)
    }

    // MARK: WAL

    func testFileDatabasesUseWALAndInMemoryDatabasesDoNot() throws {
        XCTAssertEqual(try LocalDatabase(path: path).journalMode, "wal")
        XCTAssertEqual(try LocalDatabase().journalMode, "memory")
    }

    func testWALCanBeDisabledAndLeavesTheDefaultJournal() throws {
        XCTAssertEqual(try LocalDatabase(path: path, enableWAL: false).journalMode, "delete")
    }

    func testExistingRollbackJournalStoreConvertsToWALWithoutLosingData() throws {
        do {
            let legacy = try LocalDatabase(path: path, enableWAL: false)
            XCTAssertEqual(legacy.journalMode, "delete")
            try legacy.save(item()); try legacy.save(customSettings)
            try legacy.save(AssignmentProgress(assignmentID: "a", status: .completed, updatedAt: start))
        }
        let reopened = try LocalDatabase(path: path)
        XCTAssertEqual(reopened.journalMode, "wal")
        XCTAssertEqual(try reopened.items(), [item()])
        XCTAssertEqual(try reopened.availabilitySettings(), customSettings)
        XCTAssertEqual(try reopened.assignmentProgress()["a"]?.status, .completed)
        XCTAssertEqual(try reopened.migrationCount(), 3, "WAL must not change the schema")
    }

    func testWALReadersAreNotBlockedByAnOpenWriter() throws {
        let db = try LocalDatabase(path: path, busyTimeoutMilliseconds: 50)
        try db.save(item())
        let writer = try rawConnection(); defer { sqlite3_close(writer) }
        exec(writer, "BEGIN IMMEDIATE;")
        XCTAssertEqual(try db.items(), [item()])
        exec(writer, "ROLLBACK;")
    }

    func testOpenWhileAnotherConnectionBlocksTheSwitchFailsCleanlyAndLosesNothing() throws {
        do { let legacy = try LocalDatabase(path: path, enableWAL: false); try legacy.save(item()) }
        // An open read transaction in a rollback-journal store blocks the switch to WAL and the
        // version bookkeeping write that follows it. Opening reports an error within the timeout.
        let reader = try rawConnection(); defer { sqlite3_close(reader) }
        exec(reader, "BEGIN;")
        exec(reader, "SELECT COUNT(*) FROM academic_items;")
        let started = Date()
        XCTAssertThrowsError(try LocalDatabase(path: path, busyTimeoutMilliseconds: 50)) { XCTAssertTrue($0 is DatabaseError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        exec(reader, "ROLLBACK;")
        let reopened = try LocalDatabase(path: path)
        XCTAssertEqual(reopened.journalMode, "wal")
        XCTAssertEqual(try reopened.items(), [item()])
    }
}
