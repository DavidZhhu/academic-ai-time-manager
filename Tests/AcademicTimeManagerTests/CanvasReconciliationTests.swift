import Foundation
import XCTest
import CSQLite
@testable import AcademicCore

/// Scriptable fake Canvas. Routes by path, so each simulated sync can differ. No network, token or account.
private struct FakeCanvas: CanvasTransport {
    struct Assignment { var id: Int; var name: String; var due: String? }
    struct Event { var id: Int; var title: String; var start: String; var course: Int }
    var courses: [(id: Int, name: String)] = []
    var assignments: [Int: [Assignment]] = [:]
    var secondPage: [Int: [Assignment]] = [:]
    var events: [Event] = []
    /// Forced HTTP status by route key: "courses", "assignments-N", "assignments-N-page2", "events".
    var forced: [String: Int] = [:]
    var delayAssignments = false

    private func json(_ a: Assignment) -> String {
        #"{"id":\#(a.id),"name":"\#(a.name)","due_at":\#(a.due.map { "\"\($0)\"" } ?? "null")}"#
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var headers: [String: String] = [:]
        var key = "", status = 200, body = "[]"
        if url.path == "/api/v1/courses" {
            key = "courses"
            body = "[" + courses.map { #"{"id":\#($0.id),"name":"\#($0.name)"}"# }.joined(separator: ",") + "]"
        } else if url.path.hasSuffix("/assignments"), let id = Int(url.path.split(separator: "/")[3]) {
            if delayAssignments { try await Task.sleep(for: .seconds(30)) }
            let page2 = url.query?.contains("page=2") == true
            key = "assignments-\(id)" + (page2 ? "-page2" : "")
            body = "[" + (page2 ? secondPage[id] ?? [] : assignments[id] ?? []).map(json).joined(separator: ",") + "]"
            if !page2, secondPage[id] != nil { headers["Link"] = "<https://canvas.example/api/v1/courses/\(id)/assignments?page=2>; rel=\"next\"" }
        } else if url.path == "/api/v1/calendar_events" {
            key = "events"
            body = "[" + events.map { #"{"id":\#($0.id),"title":"\#($0.title)","start_at":"\#($0.start)","end_at":"\#($0.start.replacingOccurrences(of: "10:00", with: "11:00"))","context_code":"course_\#($0.course)","context_name":"Course \#($0.course)"}"#.replacingOccurrences(of: "\n", with: "") }.joined(separator: ",") + "]"
        }
        if let forcedStatus = forced[key] { status = forcedStatus; body = "{}" }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

final class CanvasReconciliationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private let later = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
    private let eventStart = "2026-11-10T10:00:00Z"

    private func fetch(_ canvas: FakeCanvas, at date: Date? = nil) async throws -> CanvasSyncBatch {
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token-not-a-credential",
                                          transport: canvas, maxAttempts: 1, sleep: { _ in })
        return CanvasSyncBatch(result: try await importer.fetchAssignments(retrievedAt: date ?? now), completedAt: date ?? now)
    }

    @discardableResult
    private func sync(_ db: LocalDatabase, _ canvas: FakeCanvas, at date: Date? = nil) async throws -> CanvasReconciliationSummary {
        let batch = try await fetch(canvas, at: date)
        return try db.importCanvas(batch.result, successfulAt: batch.isComplete ? batch.completedAt : nil, at: date ?? now)
    }

    private var baseline: FakeCanvas {
        var canvas = FakeCanvas()
        canvas.courses = [(1, "Logic"), (2, "Algebra")]
        canvas.assignments = [
            1: [.init(id: 10, name: "Essay", due: "2027-01-10T12:00:00Z"), .init(id: 11, name: "Quiz", due: "2027-01-20T12:00:00Z")],
            2: [.init(id: 20, name: "Problem set", due: "2027-02-01T12:00:00Z")]
        ]
        canvas.events = [.init(id: 100, title: "Lecture", start: eventStart, course: 1), .init(id: 200, title: "Seminar", start: eventStart, course: 2)]
        return canvas
    }

    private func activeIDs(_ db: LocalDatabase) throws -> Set<String> { Set(try db.items().map(\.id)) }

    func testFirstSyncWithdrawsNothingAndRepeatedSyncIsIdempotent() async throws {
        let db = try LocalDatabase()
        let first = try await sync(db, baseline)
        XCTAssertFalse(first.changedAnything)
        XCTAssertEqual(try db.items().count, 5)
        let audit = try db.auditEntries().count, statuses = try db.canvasRecordStatuses()
        for _ in 0..<3 { let again = try await sync(db, baseline); XCTAssertFalse(again.changedAnything) }
        XCTAssertEqual(try db.items().count, 5)
        XCTAssertEqual(try db.auditEntries().count, audit)
        XCTAssertEqual(try db.canvasRecordStatuses(), statuses)
    }

    func testDeletedAssignmentIsWithdrawnButHistoryProgressAndAuditSurvive() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        try db.save(AssignmentProgress(assignmentID: "canvas-course-1-assignment-11", status: .completed, updatedAt: now))
        var next = baseline; next.assignments[1] = [next.assignments[1]![0]]
        let summary = try await sync(db, next, at: later)

        XCTAssertEqual(summary.withdrawnSources, 1); XCTAssertEqual(summary.withdrawnItems, 1)
        let gone = "canvas-course-1-assignment-11"
        XCTAssertFalse(try activeIDs(db).contains(gone))
        XCTAssertFalse(try db.sourceRecords().contains { $0.id == gone })
        XCTAssertTrue(try db.allItems().contains { $0.id == gone }, "Rows are flagged, never deleted")
        XCTAssertTrue(try db.allSourceRecords().contains { $0.id == gone })
        XCTAssertEqual(try db.assignmentProgress()[gone]?.status, .completed)
        XCTAssertTrue(try db.auditEntries().contains { $0.targetID == gone && $0.action == "canvas-withdrawn-item" && $0.actor == "canvas-sync" })
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), later)

        let dataset = AcademicDataset(items: try db.items(), sources: try db.sourceRecords())
        XCTAssertFalse(dataset.assignments.contains { $0.id == gone })
        XCTAssertEqual(UnifiedTimeline.events(academicItems: dataset.items, sources: dataset.sources, calendarEvents: []).filter { $0.id.contains(gone) }.count, 0)
    }

    func testWithdrawnAssignmentIsNotScheduled() async throws {
        let db = try LocalDatabase()
        var canvas = baseline; canvas.events = []
        try await sync(db, canvas)
        canvas.assignments = [1: [canvas.assignments[1]![0]], 2: []]
        try await sync(db, canvas, at: later)
        let dataset = AcademicDataset(items: try db.items(), sources: try db.sourceRecords())
        let plan = dataset.makePlan(progress: [:], availability: AvailabilitySettings(timeZoneIdentifier: "Europe/London"), now: later)
        XCTAssertFalse(plan.schedule.blocks.isEmpty)
        XCTAssertTrue(plan.schedule.blocks.allSatisfy { $0.sourceRecordIDs == ["canvas-course-1-assignment-10"] })
    }

    func testClearedDeadlineLeavesTimelineButKeepsUndatedAssignment() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var next = baseline; next.assignments[1]![0].due = nil
        let summary = try await sync(db, next, at: later)
        XCTAssertEqual(summary.withdrawnItems, 1); XCTAssertEqual(summary.withdrawnSources, 0)
        let id = "canvas-course-1-assignment-10"
        XCTAssertFalse(try activeIDs(db).contains(id))
        let dataset = AcademicDataset(items: try db.items(), sources: try db.sourceRecords())
        let assignment = try XCTUnwrap(dataset.assignments.first { $0.id == id })
        XCTAssertNil(assignment.dueAt)
        XCTAssertEqual(assignment.group(status: .notStarted, now: later), .undated)
        // Repeating the cleared-deadline sync changes nothing; restoring the date reinstates the item.
        let repeated = try await sync(db, next, at: later)
        XCTAssertFalse(repeated.changedAnything)
        let restored = try await sync(db, baseline, at: later)
        XCTAssertEqual(restored.reinstated, 1)
        XCTAssertTrue(try activeIDs(db).contains(id))
    }

    func testChangedDeadlineUpdatesInPlaceWithoutWithdrawal() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var next = baseline; next.assignments[1]![0].due = "2027-01-15T09:00:00Z"
        let summary = try await sync(db, next, at: later)
        XCTAssertFalse(summary.changedAnything)
        let item = try XCTUnwrap(db.items().first { $0.id == "canvas-course-1-assignment-10" })
        XCTAssertEqual(item.startsAt, ISO8601DateFormatter().date(from: "2027-01-15T09:00:00Z"))
        XCTAssertTrue(try db.canvasRecordStatuses().isEmpty)
    }

    func testDroppedCourseWithdrawsItsRecordsAssignmentsAndEventsOnly() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var next = baseline
        next.courses = [(1, "Logic")]; next.assignments[2] = nil; next.events = [next.events[0]]
        let summary = try await sync(db, next, at: later)
        XCTAssertEqual(summary.withdrawnSources, 3)   // course 2, its assignment, its event
        XCTAssertEqual(summary.withdrawnItems, 2)     // assignment + event
        XCTAssertEqual(try activeIDs(db), ["canvas-course-1-assignment-10", "canvas-course-1-assignment-11", "canvas-calendar-event-100"])
        XCTAssertFalse(try db.sourceRecords().contains { $0.externalID.hasPrefix("course-2") })
        XCTAssertEqual(try db.allSourceRecords().count, 7)
    }

    func testReturningRecordsAreReinstatedWithAuditAndProgressIntact() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var removed = baseline; removed.courses = [(1, "Logic")]; removed.assignments[2] = nil; removed.events = [removed.events[0]]
        try await sync(db, removed, at: later)
        try db.save(AssignmentProgress(assignmentID: "canvas-course-2-assignment-20", status: .inProgress, updatedAt: now))
        let summary = try await sync(db, baseline, at: later.addingTimeInterval(3600))
        XCTAssertEqual(summary.reinstated, 5)
        XCTAssertEqual(try activeIDs(db).count, 5)
        XCTAssertEqual(try db.assignmentProgress()["canvas-course-2-assignment-20"]?.status, .inProgress)
        XCTAssertTrue(try db.canvasRecordStatuses().allSatisfy { $0.state == .active }, "History rows are kept")
        XCTAssertTrue(try db.auditEntries().contains { $0.action == "canvas-reinstated-item" })
    }

    func testDeletedCalendarEventWithinWindowIsWithdrawnButOutsideWindowIsKept() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        // Seeded record far in the past: Canvas could not have returned it, so its absence proves nothing.
        let old = AcademicItem(id: "canvas-calendar-event-999", title: "Old", startsAt: now.addingTimeInterval(-200 * 86400),
            endsAt: now.addingTimeInterval(-200 * 86400 + 3600), timeZoneIdentifier: "UTC", kind: .classSession, verification: .verified,
            sourceRecordIDs: ["canvas-calendar-event-999"], isProtected: true)
        try db.save(SourceRecord(id: "canvas-calendar-event-999", provider: "Canvas", externalID: "calendar-event-999", retrievedAt: now))
        try db.save(old)
        var next = baseline; next.events = [next.events[1]]
        let summary = try await sync(db, next, at: later)
        XCTAssertEqual(summary.withdrawnItems, 1)
        XCTAssertFalse(try activeIDs(db).contains("canvas-calendar-event-100"))
        XCTAssertTrue(try activeIDs(db).contains("canvas-calendar-event-999"))
    }

    // MARK: partial, failed and interrupted syncs

    func testSkippedCourseKeepsItsRecordsWhileCompleteCoursesStillReconcile() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var next = baseline
        next.assignments[1] = [next.assignments[1]![0]]       // genuine deletion in a readable course
        next.forced["assignments-2"] = 403                    // course 2 unreadable this time
        let batch = try await fetch(next, at: later)
        XCTAssertFalse(batch.isComplete)
        XCTAssertEqual(batch.report.skippedCourseCount, 1)
        let summary = try db.importCanvas(batch.result, successfulAt: batch.isComplete ? batch.completedAt : nil, at: later)
        XCTAssertEqual(summary.withdrawnItems, 1)
        XCTAssertTrue(try activeIDs(db).contains("canvas-course-2-assignment-20"))
        XCTAssertFalse(try activeIDs(db).contains("canvas-course-1-assignment-11"))
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), now, "A partial sync never advances the last successful time")
    }

    func testEventFailureWithdrawsNoEvents() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var next = baseline; next.events = []; next.forced["events"] = 403
        let batch = try await fetch(next, at: later)
        XCTAssertFalse(batch.report.eventsComplete)
        let summary = try db.importCanvas(batch.result, at: later)
        XCTAssertEqual(summary.withdrawnItems, 0)
        XCTAssertEqual(try db.items().count, 5)
    }

    func testFailuresThatAreNotCourseScopedAbortWithoutChangingStoredData() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        let before = try db.allItems(), audit = try db.auditEntries().count
        for (key, status) in [("assignments-1", 500), ("assignments-1", 401), ("events", 500), ("courses", 401), ("courses", 403)] {
            var broken = baseline; broken.assignments[1] = []; broken.events = []; broken.forced[key] = status
            do { _ = try await fetch(broken, at: later); XCTFail("\(key) \(status) should abort") }
            catch { XCTAssertTrue(error is CanvasImportError) }
        }
        XCTAssertEqual(try db.allItems(), before)
        XCTAssertEqual(try db.auditEntries().count, audit)
        XCTAssertTrue(try db.canvasRecordStatuses().isEmpty)
    }

    func testSecondPageFailureMakesTheCourseIncompleteAndWithdrawsNothingThere() async throws {
        let db = try LocalDatabase()
        var paged = baseline
        paged.assignments[1] = [.init(id: 10, name: "Essay", due: "2027-01-10T12:00:00Z")]
        paged.secondPage[1] = [.init(id: 11, name: "Quiz", due: "2027-01-20T12:00:00Z")]
        try await sync(db, paged)
        XCTAssertEqual(try db.items().count, 5, "Assignments on page 2 are imported")
        let unchanged = try await sync(db, paged, at: later)
        XCTAssertFalse(unchanged.changedAnything)

        var failing = paged; failing.forced["assignments-1-page2"] = 404
        let batch = try await fetch(failing, at: later)
        XCTAssertFalse(batch.isComplete)
        XCTAssertEqual(try db.importCanvas(batch.result, at: later).withdrawnItems, 0)
        XCTAssertTrue(try activeIDs(db).contains("canvas-course-1-assignment-11"))
    }

    func testEmptyCourseListNeverWithdrawsEverything() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        var empty = FakeCanvas(); empty.courses = []
        let summary = try await sync(db, empty, at: later)
        XCTAssertFalse(summary.changedAnything)
        XCTAssertNotNil(summary.skippedReason)
        XCTAssertEqual(try db.items().count, 5)
    }

    func testCancelledSyncThrowsAndLeavesDatabaseUntouched() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        let before = try db.allItems()
        var slow = baseline; slow.assignments = [:]; slow.events = []; slow.delayAssignments = true
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token-not-a-credential",
                                          transport: slow, maxAttempts: 1, sleep: { _ in })
        let at = later
        let task = Task { try await importer.fetchAssignments(retrievedAt: at) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled sync must not produce a result") } catch {}
        XCTAssertEqual(try db.allItems(), before)
        XCTAssertTrue(try db.canvasRecordStatuses().isEmpty)
    }

    func testResultWithoutCoverageNeverWithdraws() throws {
        let db = try LocalDatabase()
        let source = SourceRecord(id: "canvas-course-1-assignment-1", provider: "Canvas", externalID: "course-1-assignment-1", retrievedAt: now)
        let item = AcademicItem(id: source.id, title: "A", startsAt: now, endsAt: now, timeZoneIdentifier: "UTC", kind: .deadline,
                                verification: .verified, sourceRecordIDs: [source.id], isProtected: true)
        try db.importCanvas(CanvasImportResult(sourceRecords: [source], academicItems: [item]))
        let summary = try db.importCanvas(CanvasImportResult(sourceRecords: [], academicItems: []))
        XCTAssertFalse(summary.changedAnything)
        XCTAssertEqual(try db.items(), [item])
    }

    // MARK: Completeness reporting

    func testMissingCoverageIsReportedIncompleteAndNeverAdvancesLastSuccessfulSync() throws {
        let batch = CanvasSyncBatch(result: CanvasImportResult(sourceRecords: [], academicItems: []), completedAt: later)
        XCTAssertNil(batch.result.coverage)
        XCTAssertFalse(batch.isComplete, "Unknown coverage must not count as a verified complete sync")
        XCTAssertFalse(batch.report.eventsComplete)

        // The same gating the app applies in synchronizeCanvas().
        let db = try LocalDatabase()
        try db.importCanvas(batch.result, successfulAt: batch.isComplete ? batch.completedAt : nil, at: later)
        XCTAssertNil(try db.lastSuccessfulCanvasSync())
    }

    func testMissingCoverageDoesNotOverwriteAnEarlierVerifiedSync() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), now)
        let unverified = CanvasSyncBatch(result: CanvasImportResult(sourceRecords: [], academicItems: []), completedAt: later)
        try db.importCanvas(unverified.result, successfulAt: unverified.isComplete ? unverified.completedAt : nil, at: later)
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), now)
        XCTAssertEqual(try db.items().count, 5, "Nothing is withdrawn without coverage")
    }

    func testFullCoverageReportsCompleteAndRecordsSuccessfulSync() async throws {
        let db = try LocalDatabase()
        let batch = try await fetch(baseline)
        XCTAssertNotNil(batch.result.coverage)
        XCTAssertTrue(batch.isComplete)
        XCTAssertTrue(batch.report.eventsComplete)
        XCTAssertEqual(batch.report.skippedCourseCount, 0)
        try db.importCanvas(batch.result, successfulAt: batch.isComplete ? batch.completedAt : nil, at: now)
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), now)
    }

    func testPartialAssignmentCoverageReportsIncomplete() async throws {
        var next = baseline
        next.forced["assignments-2"] = 403
        let batch = try await fetch(next)
        XCTAssertFalse(batch.isComplete)
        XCTAssertEqual(batch.report.skippedCourseCount, 1)
        XCTAssertTrue(batch.report.eventsComplete)
    }

    func testPartialCalendarEventCoverageReportsIncomplete() async throws {
        var next = baseline
        next.forced["events"] = 403
        let batch = try await fetch(next)
        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.report.eventsComplete)
        XCTAssertEqual(batch.report.skippedCourseCount, 0)
    }

    func testRollbackLeavesNoPartialWithdrawal() async throws {
        let path = NSTemporaryDirectory() + "reconcile-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try LocalDatabase(path: path)
        try await sync(db, baseline)
        var next = baseline; next.assignments[1] = []
        let batch = try await fetch(next, at: later)
        // An undecodable status row makes the import fail midway; every withdrawal must roll back.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        sqlite3_exec(raw, "INSERT INTO canvas_record_status VALUES ('bad','source','withdrawn','{broken');", nil, nil, nil)
        XCTAssertThrowsError(try db.importCanvas(batch.result, at: later))
        sqlite3_exec(raw, "DELETE FROM canvas_record_status WHERE record_id = 'bad';", nil, nil, nil)
        XCTAssertEqual(try db.items().count, 5)
        XCTAssertTrue(try db.canvasRecordStatuses().isEmpty)
    }

    // MARK: other providers and approved provenance

    func testSampleOutlookAndApprovedProvenanceSurviveReconciliation() async throws {
        let db = try LocalDatabase()
        try await sync(db, baseline)
        let outlook = SourceRecord(id: "outlook-1", provider: "Outlook", externalID: "acct:1", retrievedAt: now)
        let sample = SourceRecord(id: "source-canvas-demo", provider: "Canvas (sample)", externalID: "demo", retrievedAt: now)
        try db.save(outlook); try db.save(sample)
        // An Outlook-approved commitment merged into a Canvas event keeps both sources.
        var merged = try XCTUnwrap(db.items().first { $0.id == "canvas-calendar-event-100" })
        merged.sourceRecordIDs.append("outlook-1"); try db.save(merged)
        let demoItem = AcademicItem(id: "demo-item", title: "Demo", startsAt: now, endsAt: now, timeZoneIdentifier: "UTC", kind: .deadline,
            verification: .verified, sourceRecordIDs: ["source-canvas-demo"], isProtected: true)
        try db.save(demoItem)

        var next = baseline; next.events = [next.events[1]]
        let summary = try await sync(db, next, at: later)
        XCTAssertEqual(summary.detachedItems, 1)
        XCTAssertEqual(summary.withdrawnSources, 1)
        let kept = try XCTUnwrap(db.items().first { $0.id == "canvas-calendar-event-100" })
        XCTAssertEqual(kept.sourceRecordIDs, ["outlook-1"])
        XCTAssertTrue(try db.items().contains(demoItem))
        XCTAssertTrue(try db.sourceRecords().contains(outlook))
        XCTAssertTrue(try db.sourceRecords().contains(sample))
    }

    // MARK: backward compatibility

    func testVersionThreeStoreOpensAdditivelyKeepsEveryRowAndThenReconciles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy.sqlite").path
        do {
            let db = try LocalDatabase(path: path)
            try await sync(db, baseline)       // stale data a pre-reconciliation build would have kept
            try db.save(AssignmentProgress(assignmentID: "canvas-course-1-assignment-11", status: .completed, updatedAt: now))
            try db.save(AvailabilitySettings(timeZoneIdentifier: "Europe/London"))
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TABLE canvas_record_status; DELETE FROM schema_migrations WHERE version = 4;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let db = try LocalDatabase(path: path)
        XCTAssertEqual(try db.migrationCount(), 4)
        XCTAssertEqual(try db.items().count, 5, "Opening an old store changes no rows")
        XCTAssertEqual(try db.sourceRecordCount(), 7)
        XCTAssertEqual(try db.assignmentProgress().count, 1)
        XCTAssertNotNil(try db.availabilitySettings())
        XCTAssertTrue(try db.canvasRecordStatuses().isEmpty)

        var next = baseline; next.assignments[1] = [next.assignments[1]![0]]
        let summary = try await sync(db, next, at: later)
        XCTAssertEqual(summary.withdrawnItems, 1)
        XCTAssertEqual(try db.assignmentProgress().count, 1)
    }
}
