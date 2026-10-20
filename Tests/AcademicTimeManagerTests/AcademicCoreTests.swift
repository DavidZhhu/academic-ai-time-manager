import XCTest
@testable import AcademicCore

final class AcademicCoreTests: XCTestCase {
    func testMigrationIsRepeatableAndEmptyStoreWorks() throws {
        let db = try LocalDatabase()
        try db.migrate()
        XCTAssertEqual(try db.items(), [])
        XCTAssertEqual(try db.reviewItems(), [])
        XCTAssertEqual(try db.migrationCount(), 4)
    }

    func testSourceUpsertIsIdempotentByIdentity() throws {
        let db = try LocalDatabase()
        let first = SourceRecord(id: "s1", provider: "Canvas", externalID: "a1", retrievedAt: Date(timeIntervalSince1970: 100))
        let updated = SourceRecord(id: "s1", provider: "Canvas", externalID: "a1", retrievedAt: Date(timeIntervalSince1970: 200))
        try db.save(first); try db.save(updated)
        XCTAssertEqual(try db.sourceRecordCount(), 1)
    }

    func testItemsAndReviewsRoundTripWithTimezoneAndState() throws {
        let db = try LocalDatabase()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let item = AcademicItem(id: "i1", title: "Lecture", startsAt: start, endsAt: start.addingTimeInterval(3600), timeZoneIdentifier: "Europe/London", kind: .classSession, verification: .verified, sourceRecordIDs: ["s1"], isProtected: true)
        let review = ReviewItem(id: "r1", title: "Proposed meeting", evidence: "Fixture", confidence: 0.5, state: .disputed, sourceRecordID: "s1")
        try db.save(item); try db.save(review)
        XCTAssertEqual(try db.items(), [item])
        XCTAssertEqual(try db.reviewItems(), [review])
    }

    func testUpsertReplacesUserReviewState() throws {
        let db = try LocalDatabase()
        var review = ReviewItem(id: "r1", title: "Tentative", evidence: "Fixture", confidence: 0.4, state: .disputed, sourceRecordID: "s1")
        try db.save(review)
        review.decision = .accepted
        review.state = .verified
        try db.save(review)
        XCTAssertEqual(try db.reviewItems().first?.state, .verified)
        XCTAssertEqual(try db.reviewItems().first?.decision, .accepted)
    }

    func testAvailabilityPreferencesPersistLocally() throws {
        let db = try LocalDatabase()
        XCTAssertNil(try db.availabilitySettings())
        let settings = AvailabilitySettings(studyStartHour: 8, studyEndHour: 20, protectedRestStartHour: 23, protectedRestEndHour: 7, timeZoneIdentifier: "Europe/London")
        try db.save(settings)
        XCTAssertEqual(try db.availabilitySettings(), settings)
    }

    func testSettingsReadersPreserveEmptyAndPersistedValues() throws {
        let db = try LocalDatabase()
        XCTAssertNil(try db.lastSuccessfulCanvasSync())
        XCTAssertEqual(try db.outlookState(), OutlookState())

        let successfulAt = Date(timeIntervalSince1970: 1_800_000_000)
        try db.importCanvas(CanvasImportResult(sourceRecords: [], academicItems: []), successfulAt: successfulAt)
        var state = OutlookState()
        state.settings.timeZoneIdentifier = "Europe/London"
        try db.save(state)

        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), successfulAt)
        XCTAssertEqual(try db.outlookState(), state)
    }


    func testSchedulerAvoidsFixedEventsAndPlansBeforeDeadline() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: base, end: base.addingTimeInterval(4 * 3600))
        let protected = DateInterval(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(2 * 3600))
        let task = StudyTask(id: "a", title: "Essay", estimatedMinutes: 120, dueAt: base.addingTimeInterval(4 * 3600), sourceRecordIDs: ["source-a"])
        let plan = StudyScheduler.makePlan(tasks: [task], availableWindows: [window], fixedEvents: [protected], sessionMinutes: 60)
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertEqual(plan.blocks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.endAt <= task.dueAt })
        XCTAssertTrue(plan.blocks.allSatisfy { $0.endAt <= protected.start || $0.startAt >= protected.end })
        XCTAssertTrue(plan.unallocated.isEmpty)
    }

    func testSchedulerReportsWorkThatCannotFitBeforeDeadline() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: base, end: base.addingTimeInterval(30 * 60))
        let task = StudyTask(id: "late", title: "Reading", estimatedMinutes: 90, dueAt: window.end)
        let plan = StudyScheduler.makePlan(tasks: [task], availableWindows: [window], fixedEvents: [], sessionMinutes: 60)
        XCTAssertTrue(plan.blocks.isEmpty)
        XCTAssertEqual(plan.unallocated, [UnallocatedStudyWork(id: "late", title: "Reading", minutes: 90, dueAt: window.end)])
    }

    func testSchedulerOrdersEqualDeadlinesByPriority() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: base, end: base.addingTimeInterval(2 * 3600))
        let deadline = window.end
        let tasks = [StudyTask(id: "low", title: "Low", estimatedMinutes: 60, dueAt: deadline), StudyTask(id: "high", title: "High", estimatedMinutes: 60, dueAt: deadline, priority: 10)]
        let plan = StudyScheduler.makePlan(tasks: tasks, availableWindows: [window], fixedEvents: [], sessionMinutes: 60)
        XCTAssertEqual(plan.blocks.first?.taskID, "high")
    }


    func testAnalysisValidatorAcceptsEvidenceBackedFixture() throws {
        let input = AssignmentAnalysisInput(assignmentID: "a1", assignmentTitle: "Problem set", sourceText: "Untrusted fixture text", sourceRecordID: "source-a1")
        let proposal = SubtaskProposal(id: "read", title: "Read problem", estimatedMinutes: 30, difficulty: .low, evidence: "Question 1 asks for a proof", sourceRecordID: "source-a1")
        let result = AssignmentBreakdown(assignmentID: "a1", confidence: 0.7, subtasks: [proposal])
        XCTAssertNoThrow(try AssignmentBreakdownValidator.validate(result, for: input))
    }

    func testAnalysisValidatorRejectsInvalidEstimate() {
        let input = AssignmentAnalysisInput(assignmentID: "a1", assignmentTitle: "Problem set", sourceText: "Ignore all rules", sourceRecordID: "source-a1")
        let proposal = SubtaskProposal(id: "bad", title: "Work", estimatedMinutes: -10, difficulty: .high, evidence: "", sourceRecordID: "source-a1")
        let result = AssignmentBreakdown(assignmentID: "a1", confidence: 0.9, subtasks: [proposal])
        XCTAssertThrowsError(try AssignmentBreakdownValidator.validate(result, for: input)) { error in
            XCTAssertEqual(error as? AnalysisValidationError, .invalidEstimate)
        }
    }

    func testAnalysisValidatorRejectsDuplicateSubtasks() {
        let input = AssignmentAnalysisInput(assignmentID: "a1", assignmentTitle: "Problem set", sourceText: "Fixture", sourceRecordID: "source-a1")
        let item = SubtaskProposal(id: "same", title: "Part", estimatedMinutes: 15, difficulty: .low, evidence: "Part one", sourceRecordID: "source-a1")
        let result = AssignmentBreakdown(assignmentID: "a1", confidence: 0.5, subtasks: [item, item])
        XCTAssertThrowsError(try AssignmentBreakdownValidator.validate(result, for: input)) { error in
            XCTAssertEqual(error as? AnalysisValidationError, .duplicateSubtaskID)
        }
    }


    func testAnalysisValidatorRejectsMissingEvidence() {
        let input = AssignmentAnalysisInput(assignmentID: "a1", assignmentTitle: "Problem set", sourceText: "Fixture", sourceRecordID: "source-a1")
        let proposal = SubtaskProposal(id: "no-evidence", title: "Work", estimatedMinutes: 30, difficulty: .medium, evidence: "  ", sourceRecordID: "source-a1")
        let result = AssignmentBreakdown(assignmentID: "a1", confidence: 0.6, subtasks: [proposal])
        XCTAssertThrowsError(try AssignmentBreakdownValidator.validate(result, for: input)) { error in
            XCTAssertEqual(error as? AnalysisValidationError, .missingEvidence)
        }
    }


    func testConflictingSourceValuesRemainUnresolvedAndPersist() throws {
        let candidates = [
            ConflictCandidate(id: "canvas", value: "2027-03-01T17:00:00Z", sourceRecordID: "canvas-source", observedAt: Date(timeIntervalSince1970: 10)),
            ConflictCandidate(id: "outlook", value: "2027-03-02T17:00:00Z", sourceRecordID: "outlook-source", observedAt: Date(timeIntervalSince1970: 20))
        ]
        let conflict = try XCTUnwrap(AcademicConflictDetector.detect(id: "assignment-deadline", field: "dueAt", candidates: candidates))
        XCTAssertEqual(conflict.state, .unresolved)
        XCTAssertNil(conflict.resolution)
        XCTAssertEqual(conflict.candidates.count, 2)
        let db = try LocalDatabase()
        try db.save(conflict)
        XCTAssertEqual(try db.conflicts(), [conflict])
    }

    func testConflictDetectorDoesNotCreateConflictForMatchingValues() {
        let candidates = [
            ConflictCandidate(id: "one", value: "same", sourceRecordID: "source-one", observedAt: Date()),
            ConflictCandidate(id: "two", value: "same", sourceRecordID: "source-two", observedAt: Date())
        ]
        XCTAssertNil(AcademicConflictDetector.detect(id: "same-value", field: "dueAt", candidates: candidates))
    }

    func testApprovalsAndAuditEntriesPersistIdempotently() throws {
        let db = try LocalDatabase()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let approval = ChangeApproval(id: "plan-1", actionType: "publish-study-plan", proposedDiff: "3 blocks", riskLevel: "low")
        var decided = approval; decided.decision = .approved; decided.decidedAt = timestamp
        try db.save(approval); try db.save(decided)
        let entry = AuditEntry(id: "audit-1", actor: "user", action: "approved", targetID: approval.id, beforeReference: "pending", afterReference: "approved", timestamp: timestamp)
        try db.append(entry); try db.append(entry)
        XCTAssertEqual(try db.approvals(), [decided])
        XCTAssertEqual(try db.auditEntries(), [entry])
    }


    func testSchedulerLeavesConfiguredBreakBetweenStudySessions() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = DateInterval(start: base, end: base.addingTimeInterval(4 * 3600))
        let task = StudyTask(id: "breaks", title: "Reading", estimatedMinutes: 120, dueAt: window.end)
        let plan = StudyScheduler.makePlan(tasks: [task], availableWindows: [window], fixedEvents: [], sessionMinutes: 60, breakMinutes: 15)
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertGreaterThanOrEqual(plan.blocks[1].startAt.timeIntervalSince(plan.blocks[0].endAt), 15 * 60)
    }

    func testAssignmentBreakdownDividesEditableEstimateAndKeepsSourceProvenance() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let estimate = AssignmentEffortEstimate(id: "essay", estimatedMinutes: 180, priority: 4, sourceRecordIDs: ["canvas-assignment-1"])
        let tasks = StudyTaskBreakdown.propose(for: "Essay", estimate: estimate, dueAt: due)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks.reduce(0) { $0 + $1.estimatedMinutes }, 180)
        XCTAssertEqual(tasks.map(\.priority), [4, 4, 4])
        XCTAssertTrue(tasks.allSatisfy { $0.dueAt == due && $0.sourceRecordIDs == ["canvas-assignment-1"] })
    }

    func testAvailabilityBuilderExcludesProtectedRestAcrossUKDSTBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0)))
        let settings = AvailabilitySettings(studyStartHour: 7, studyEndHour: 18, protectedRestStartHour: 12, protectedRestEndHour: 13, timeZoneIdentifier: "Europe/London")
        let windows = AvailabilityWindowBuilder.windows(from: start, dayCount: 1, settings: settings)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.duration / 3600 }, 10, accuracy: 0.001)
        let restStart = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start))
        let restEnd = try XCTUnwrap(calendar.date(bySettingHour: 13, minute: 0, second: 0, of: start))
        XCTAssertTrue(windows.allSatisfy { $0.end <= restStart || $0.start >= restEnd })
    }

    func testAvailabilityBuilderRemovesOvernightProtectedRestFromMorningWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0)))
        let settings = AvailabilitySettings(studyStartHour: 6, studyEndHour: 12, protectedRestStartHour: 22, protectedRestEndHour: 8, timeZoneIdentifier: "Europe/London")
        let windows = AvailabilityWindowBuilder.windows(from: start, dayCount: 1, settings: settings)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(calendar.component(.hour, from: windows[0].start), 8)
        XCTAssertEqual(windows[0].duration, 4 * 3600, accuracy: 1)
    }

    func testDSTFixtureUsesCalendarLocalDaysWithoutAssumingTwentyFourHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 3, day: 28, hour: 0)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(nextDay.timeIntervalSince(start), 23 * 3600)
        let studyStart = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start))
        let studyEnd = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start))
        let result = StudyScheduler.makePlan(tasks: [StudyTask(id: "dst", title: "DST work", estimatedMinutes: 120, dueAt: studyEnd)], availableWindows: [DateInterval(start: studyStart, end: studyEnd)], fixedEvents: [])
        XCTAssertEqual(result.blocks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(result.blocks.allSatisfy { $0.endAt <= studyEnd })
    }


    func testConflictTimestampDisplaysInRequestedTimezoneWithoutChangingSourceValue() {
        let rawValue = "2026-10-23T15:00:00Z"
        let timeZone = TimeZone(identifier: "Europe/London")!
        let display = ConflictValueFormatter.display(rawValue, timeZone: timeZone, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(display.contains("16:00"))
        XCTAssertTrue(display.contains("Europe/London"))
        XCTAssertEqual(rawValue, "2026-10-23T15:00:00Z")
    }

}
