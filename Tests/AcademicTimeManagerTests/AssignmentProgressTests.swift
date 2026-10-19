import XCTest
import CSQLite
@testable import AcademicCore

final class AssignmentProgressTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!
    private let availability = AvailabilitySettings(timeZoneIdentifier: "Europe/London")

    private func deadline(_ id: String, due: Date) -> AcademicItem {
        AcademicItem(id: id, title: id, startsAt: due, endsAt: due, timeZoneIdentifier: "Europe/London",
                     kind: .deadline, verification: .verified, sourceRecordIDs: [id], isProtected: true)
    }

    func testStatusesPersistAcrossDatabaseReopenAndCanBeReopened() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        do {
            let db = try LocalDatabase(path: path)
            for (index, status) in AssignmentStatus.allCases.enumerated() {
                try db.save(AssignmentProgress(assignmentID: "assignment-\(index)", status: status, updatedAt: now))
            }
        }
        do {
            let db = try LocalDatabase(path: path)
            let progress = try db.assignmentProgress()
            for (index, status) in AssignmentStatus.allCases.enumerated() {
                XCTAssertEqual(progress["assignment-\(index)"]?.status, status)
                XCTAssertEqual(progress["assignment-\(index)"]?.updatedAt, now)
            }
            try db.save(AssignmentProgress(assignmentID: "assignment-2", status: .inProgress, updatedAt: now.addingTimeInterval(1)))
        }
        let reopened = try LocalDatabase(path: path)
        XCTAssertEqual(try reopened.assignmentProgress()["assignment-2"]?.status, .inProgress)
        XCTAssertEqual(try reopened.assignmentProgress().count, 3)
    }

    func testVersionTwoStoreMigratesWithoutChangingCachedItemsOrSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let item = deadline("legacy", due: now)
        do {
            let db = try LocalDatabase(path: path)
            try db.save(item)
            try db.save(availability)
        }
        // Construct a v2 fixture only. No production database is opened by this test.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE assignment_progress; DELETE FROM schema_migrations WHERE version = 3;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let migrated = try LocalDatabase(path: path)
        try migrated.migrate()
        XCTAssertEqual(try migrated.migrationCount(), 3)
        XCTAssertEqual(try migrated.items(), [item])
        XCTAssertEqual(try migrated.availabilitySettings(), availability)
        XCTAssertTrue(try migrated.assignmentProgress().isEmpty)
    }

    func testRepeatedCanvasImportsPreserveEveryLocalStatusWhileUpdatingSourceFacts() throws {
        let db = try LocalDatabase()
        for (index, status) in AssignmentStatus.allCases.enumerated() {
            let id = "canvas-course-1-assignment-\(index)"
            try db.save(AssignmentProgress(assignmentID: id, status: status, updatedAt: now))
            for offset in [1.0, 2.0] {
                let item = deadline(id, due: now.addingTimeInterval(offset * 86_400))
                let source = SourceRecord(id: id, provider: "Canvas", externalID: "course-1-assignment-\(index)",
                    retrievedAt: now.addingTimeInterval(offset), displayTitle: "Updated title \(offset)",
                    assignmentDetails: ImportedAssignmentDetails(dueAt: item.startsAt))
                try db.importCanvas(CanvasImportResult(sourceRecords: [source], academicItems: [item]))
            }
            XCTAssertEqual(try db.assignmentProgress()[id], AssignmentProgress(assignmentID: id, status: status, updatedAt: now))
        }
        XCTAssertEqual(try db.items().count, 3)
        XCTAssertTrue(try db.items().allSatisfy { $0.startsAt == now.addingTimeInterval(2 * 86_400) })
        XCTAssertTrue(try db.sourceRecords().allSatisfy { $0.displayTitle == "Updated title 2.0" })
    }

    func testCompletedAndOverdueNeverCreateWorkOrWarningsButFutureCapacityWarningsRemain() {
        let items = [deadline("past", due: now.addingTimeInterval(-1)), deadline("at-boundary", due: now),
                     deadline("completed", due: now.addingTimeInterval(86_400)),
                     deadline("future-too-tight", due: now.addingTimeInterval(60)),
                     deadline("in-progress", due: now.addingTimeInterval(8 * 3600))]
        let progress = ["completed": AssignmentProgress(assignmentID: "completed", status: .completed),
                        "in-progress": AssignmentProgress(assignmentID: "in-progress", status: .inProgress)]
        let assignments = AssignmentPlanning.assignments(items: items, sources: [])
        let plan = AssignmentPlanning.makePlan(assignments: assignments, progress: progress, items: items,
            availability: availability, estimates: ["in-progress": 30], now: now)
        XCTAssertFalse(plan.schedule.blocks.isEmpty)
        XCTAssertTrue(plan.schedule.blocks.allSatisfy { $0.sourceRecordIDs == ["in-progress"] && $0.startAt >= now })
        XCTAssertFalse(plan.schedule.unallocated.isEmpty)
        XCTAssertTrue(plan.schedule.unallocated.allSatisfy { $0.id.hasPrefix("future-too-tight-stage-") })
        XCTAssertFalse(plan.isCurrent(at: now.addingTimeInterval(60)))
        let expired = AssignmentPlanning.makePlan(assignments: assignments, progress: progress, items: items,
            availability: availability, now: now.addingTimeInterval(60))
        XCTAssertFalse(expired.schedule.unallocated.contains { $0.id.hasPrefix("future-too-tight-") })
    }

    func testReopenedFutureAssignmentReturnsToSchedulingButReopenedPastAssignmentStaysOverdue() {
        let items = [deadline("future", due: now.addingTimeInterval(8 * 3600)), deadline("past", due: now.addingTimeInterval(-1))]
        let assignments = AssignmentPlanning.assignments(items: items, sources: [])
        let complete = Dictionary(uniqueKeysWithValues: items.map { ($0.id, AssignmentProgress(assignmentID: $0.id, status: .completed)) })
        let plan = AssignmentPlanning.makePlan(assignments: assignments, progress: complete, items: items, availability: availability, now: now)
        XCTAssertTrue(plan.schedule.blocks.isEmpty)
        XCTAssertTrue(plan.schedule.unallocated.isEmpty)
        XCTAssertTrue(assignments.allSatisfy { $0.group(status: .completed, now: now) == .completed })
        let reopened = AssignmentPlanning.makePlan(assignments: assignments, progress: [:], items: items, availability: availability, now: now)
        XCTAssertFalse(reopened.schedule.blocks.isEmpty)
        XCTAssertTrue(reopened.schedule.blocks.allSatisfy { $0.sourceRecordIDs == ["future"] })
        XCTAssertTrue(reopened.schedule.unallocated.isEmpty)
        XCTAssertEqual(assignments.first(where: { $0.id == "past" })?.group(status: .notStarted, now: now), .overdue)
    }

    func testDeadlineBoundaryUsesAbsoluteTimeAcrossRepeatedUKDSTHour() throws {
        let due = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:30:00+01:00"))
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:15:00+00:00"))
        let assignment = try XCTUnwrap(AssignmentPlanning.assignments(items: [deadline("dst", due: due)], sources: []).first)
        XCTAssertEqual(assignment.group(status: .notStarted, now: due.addingTimeInterval(-1)), .active)
        XCTAssertEqual(assignment.group(status: .inProgress, now: due), .overdue)
        XCTAssertEqual(assignment.group(status: .inProgress, now: after), .overdue)
        XCTAssertEqual(assignment.group(status: .completed, now: after), .completed)
    }

    func testUndatedImportOverridesStaleDeadlineAndCanStillBeCompleted() throws {
        let item = deadline("undated", due: now.addingTimeInterval(86_400))
        let source = SourceRecord(id: item.id, provider: "Canvas", externalID: "assignment", retrievedAt: now,
            displayTitle: "Reading", assignmentDetails: ImportedAssignmentDetails(dueAt: nil))
        let assignments = AssignmentPlanning.assignments(items: [item], sources: [source])
        XCTAssertEqual(assignments.count, 1)
        XCTAssertNil(assignments[0].dueAt)
        XCTAssertEqual(assignments[0].group(status: .inProgress, now: now), .undated)
        XCTAssertEqual(assignments[0].group(status: .completed, now: now), .completed)
        let plan = AssignmentPlanning.makePlan(assignments: assignments, progress: [:], items: [item], availability: availability, now: now)
        XCTAssertTrue(plan.schedule.blocks.isEmpty)
        XCTAssertTrue(plan.schedule.unallocated.isEmpty)
    }

    func testLegacySourceRecordsDecodeWithoutAssignmentMetadata() throws {
        let source = try JSONDecoder().decode(SourceRecord.self, from: Data(#"{"id":"legacy","provider":"Canvas","externalID":"assignment","retrievedAt":0}"#.utf8))
        XCTAssertNil(source.assignmentDetails)
        XCTAssertNil(source.displayTitle)
    }

    func testPlanningAfterStudyHoursSkipsTodayWithoutInvalidDateInterval() {
        let evening = now.addingTimeInterval(12 * 3600)
        let windows = AvailabilityWindowBuilder.windows(from: evening, dayCount: 2, settings: availability)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.start > evening && $0.duration > 0 })
    }
}
