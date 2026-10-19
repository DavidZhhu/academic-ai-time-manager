import Foundation
import XCTest
@testable import AcademicCore

@MainActor private final class MockCalendar: AppleCalendarClient {
    private final class Observation: AppleCalendarChangeObservation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var access: CalendarAccess = .fullAccess
    var values: [AppleCalendarEvent] = []
    var permissionRequests = 0
    var reads = 0
    var writes = 0
    var creates = 0
    var calendarAvailable = true
    var readError = false
    var failBeforeWrite = false
    var failAfterWrite = false
    var onWrite: (() -> Void)?
    var changeHandler: (@MainActor () -> Void)?
    func requestAccess() async throws { permissionRequests += 1 }
    func sources() throws -> [AppleCalendarSource] { [AppleCalendarSource(id: "local", title: "Test account")] }
    func createCalendar(sourceID: String) throws -> String { creates += 1; return "managed" }
    func validateCalendar(id: String) throws { if !calendarAvailable { throw AppleCalendarError.unavailable } }
    func events(in interval: DateInterval) throws -> [AppleCalendarEvent] {
        reads += 1
        if readError { throw AppleCalendarError.unavailable }
        return values.filter { $0.start < interval.end && $0.end > interval.start }
    }
    func event(id: String) throws -> AppleCalendarEvent? { values.first { $0.id == id } }
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleCalendarChangeObservation {
        let observation = Observation()
        changeHandler = { if !observation.cancelled { handler() } }
        return observation
    }
    func notifyCalendarChanged() { changeHandler?() }
    func apply(before: AppleCalendarEvent?, after: AppleCalendarEvent?) throws -> AppleCalendarEvent? {
        if failBeforeWrite { throw AppleCalendarError.unavailable }
        writes += 1
        if let before { values.removeAll { $0.id == before.id } }
        var saved = after
        if saved != nil { saved!.id = before?.id ?? UUID().uuidString; values.append(saved!) }
        onWrite?()
        if failAfterWrite { throw AppleCalendarError.unavailable }
        return saved
    }
}

@MainActor private final class MemoryCalendarJournal: CalendarJournalStore {
    var value = CalendarJournal()
    var failSave = false
    func load() throws -> CalendarJournal { value }
    func save(_ journal: CalendarJournal) throws { if failSave { throw AppleCalendarError.storage }; value = journal }
}

final class AppleCalendarTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func block(_ offset: TimeInterval = 3600, task: String = "task", title: String = "Study") -> ScheduledStudyBlock {
        ScheduledStudyBlock(id: "\(task)-\(offset)", taskID: task, title: title, startAt: instant.addingTimeInterval(offset),
            endAt: instant.addingTimeInterval(offset + 1800), sourceRecordIDs: ["source"])
    }
    @MainActor private func setup() throws -> (AppleCalendarService, MockCalendar, MemoryCalendarJournal) {
        let client = MockCalendar(); let storage = MemoryCalendarJournal(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        try service.createCalendar(sourceID: "local", approved: true)
        return (service, client, storage)
    }
    @MainActor private func preview(_ service: AppleCalendarService, blocks: [ScheduledStudyBlock]? = nil, cancel: Set<String> = []) throws -> CalendarPreview {
        try service.preview(blocks: blocks ?? [block()], timeZone: "Europe/London", mode: .live,
                            expiresAt: instant.addingTimeInterval(86400), cancelKeys: cancel)
    }
    @MainActor func testConstructionDoesNotRequestPermissionReadOrWrite() async throws {
        let client = MockCalendar(); client.access = .notDetermined
        let service = try AppleCalendarService(client: client, storage: MemoryCalendarJournal())
        XCTAssertEqual(client.reads, 0); XCTAssertEqual(client.writes, 0); XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertThrowsError(try service.createCalendar(sourceID: "local", approved: false))
        XCTAssertThrowsError(try service.createCalendar(sourceID: "local", approved: true))
        XCTAssertEqual(client.creates, 0)
        do { try await service.requestAccess(); XCTFail("Permission remains denied") } catch {}
        XCTAssertEqual(client.permissionRequests, 1)
    }
    @MainActor func testPreviewDoesNotWriteAndApprovalCannotBeReplayed() async throws {
        let (service, client, storage) = try setup()
        let proposal = try preview(service)
        XCTAssertEqual(client.writes, 0); XCTAssertTrue(storage.value.records.isEmpty)
        try service.approve(proposal)
        XCTAssertEqual(client.writes, 1); XCTAssertEqual(storage.value.records.count, 1)
        XCTAssertThrowsError(try service.approve(proposal)); XCTAssertEqual(client.writes, 1)
        XCTAssertEqual(storage.value.audit.map(\.action), ["approved-create", "confirmed"])
    }
    @MainActor func testRepeatedPublicationAndRestartDoNotDuplicate() async throws {
        let (service, client, storage) = try setup()
        try service.approve(preview(service))
        let now = instant
        let restarted = try AppleCalendarService(client: client, storage: storage, now: { now })
        try restarted.createCalendar(sourceID: "local", approved: true)
        XCTAssertEqual(client.creates, 1)
        let again = try preview(restarted)
        XCTAssertTrue(again.changes.isEmpty)
        try restarted.approve(again)
        XCTAssertEqual(client.writes, 1); XCTAssertEqual(client.values.count, 1)
    }
    @MainActor func testUpdateUsesStableTaskSlotAndCancellationOnlyRemovesOwnedEvent() async throws {
        let (service, client, storage) = try setup()
        try service.approve(preview(service))
        let id = try XCTUnwrap(client.values.first?.id)
        let updated = try preview(service, blocks: [block(7200, title: "Revised study")])
        XCTAssertEqual(updated.changes.first?.label, "Update")
        try service.approve(updated)
        XCTAssertEqual(client.values.first?.id, id); XCTAssertEqual(client.values.count, 1)
        var personal = client.values[0]; personal.id = "personal"; personal.marker = nil; personal.calendarID = "personal-calendar"
        client.values.append(personal)
        let key = try XCTUnwrap(storage.value.records.keys.first)
        let cancellation = try preview(service, blocks: [], cancel: [key])
        XCTAssertEqual(cancellation.changes.first?.label, "Cancel")
        try service.approve(cancellation)
        XCTAssertEqual(client.values.map(\.id), ["personal"])
        XCTAssertTrue(storage.value.records.isEmpty)
    }
    @MainActor func testExternalEditMoveRecurrenceOrDeletionIsProtected() async throws {
        for mutation in 0..<4 {
            let (service, client, _) = try setup()
            try service.approve(preview(service))
            switch mutation {
            case 0: client.values[0].title = "User edit"
            case 1: client.values[0].calendarID = "personal"
            case 2: client.values[0].isSafeToModify = false
            default: client.values.removeAll()
            }
            XCTAssertThrowsError(try preview(service, blocks: [block(7200)]))
            XCTAssertThrowsError(try preview(service, blocks: [], cancel: Set(service.managedKeys())))
            XCTAssertEqual(client.writes, 1)
        }
    }
    @MainActor func testDuplicateMarkersBlockUpdates() async throws {
        let (service, client, _) = try setup(); try service.approve(preview(service))
        var duplicate = client.values[0]; duplicate.id = "duplicate"; client.values.append(duplicate)
        XCTAssertThrowsError(try preview(service, blocks: [block(7200)]))
        XCTAssertEqual(client.writes, 1)
    }
    @MainActor func testChangedEventIdentifierIsRecoveredByMarker() async throws {
        let (service, client, _) = try setup(); try service.approve(preview(service))
        client.values[0].id = "new-provider-id"
        let update = try preview(service, blocks: [block(7200)])
        XCTAssertEqual(update.changes[0].before?.id, "new-provider-id")
        try service.approve(update); XCTAssertEqual(client.values.count, 1)
    }
    @MainActor func testBusyConflictAppearingAfterPreviewBlocksAllWrites() async throws {
        let (service, client, _) = try setup(); let proposal = try preview(service)
        let b = block()
        client.values = [AppleCalendarEvent(id: "meeting", calendarID: "personal", marker: nil, title: "Private", start: b.startAt,
            end: b.endAt, timeZone: "Europe/London", isSafeToModify: false)]
        XCTAssertThrowsError(try service.approve(proposal)) { XCTAssertEqual($0 as? AppleCalendarError, .conflict) }
        XCTAssertEqual(client.writes, 0)
        XCTAssertThrowsError(try preview(service))
    }
    @MainActor func testAllDayBusyAndFreeEventsAndAdjacentBoundary() async throws {
        let (service, client, _) = try setup()
        client.values = [AppleCalendarEvent(id: "all-day", calendarID: "personal", marker: nil, title: "Away", start: instant,
            end: instant.addingTimeInterval(86400), timeZone: "Europe/London", isSafeToModify: false)]
        XCTAssertThrowsError(try preview(service))
        client.values[0].isBusy = false
        XCTAssertNoThrow(try preview(service))
        client.values[0].isBusy = true; client.values[0].end = block().startAt
        XCTAssertNoThrow(try preview(service))
    }
    @MainActor func testOverlappingProposalDemoAndInvalidTimeZoneAreRejected() async throws {
        let (service, client, _) = try setup()
        XCTAssertThrowsError(try preview(service, blocks: [block(), block(4000, task: "other")]))
        XCTAssertThrowsError(try preview(service, blocks: [block(-3600)]))
        XCTAssertThrowsError(try service.preview(blocks: [block()], timeZone: "Europe/London", mode: .demo, expiresAt: instant.addingTimeInterval(86400)))
        XCTAssertThrowsError(try service.preview(blocks: [block()], timeZone: "invalid", mode: .live, expiresAt: instant.addingTimeInterval(86400)))
        XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testRevocationAndReadFailuresFailClosed() async throws {
        for access in [CalendarAccess.denied, .restricted, .writeOnly, .notDetermined] {
            let (service, client, _) = try setup(); let proposal = try preview(service)
            client.access = access
            XCTAssertThrowsError(try service.approve(proposal))
            XCTAssertThrowsError(try service.busyIntervals(in: DateInterval(start: instant, duration: 86400)))
            XCTAssertEqual(client.writes, 0)
        }
        let (service, client, _) = try setup(); let proposal = try preview(service); client.readError = true
        XCTAssertThrowsError(try service.approve(proposal)); XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testDeletedOrReadOnlyCalendarPreventsPublication() async throws {
        let (service, client, _) = try setup(); let proposal = try preview(service); client.calendarAvailable = false
        XCTAssertThrowsError(try service.approve(proposal)); XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testStorageFailureBeforeWritePreventsCalendarMutation() async throws {
        let (service, client, storage) = try setup(); let proposal = try preview(service); storage.failSave = true
        XCTAssertThrowsError(try service.approve(proposal)); XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testSuccessfulWriteWithFailedJournalSaveRecoversAcrossRestart() async throws {
        let (service, client, storage) = try setup(); let proposal = try preview(service)
        client.onWrite = { storage.failSave = true }
        XCTAssertThrowsError(try service.approve(proposal)); XCTAssertTrue(service.hasPendingWrite)
        storage.failSave = false; client.onWrite = nil
        let now = instant; let restarted = try AppleCalendarService(client: client, storage: storage, now: { now })
        XCTAssertThrowsError(try preview(restarted))
        try restarted.recoverPendingWrite()
        XCTAssertFalse(restarted.hasPendingWrite)
        XCTAssertTrue(try preview(restarted).changes.isEmpty)
        XCTAssertEqual(client.writes, 1)
    }
    @MainActor func testUncertainCreateNeverRetriesBlindly() async throws {
        let (service, client, _) = try setup(); client.failBeforeWrite = true
        XCTAssertThrowsError(try service.approve(preview(service)))
        XCTAssertThrowsError(try service.recoverPendingWrite())
        XCTAssertThrowsError(try preview(service)); XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testCommitThenErrorReconcilesWithoutRetry() async throws {
        let (service, client, _) = try setup(); client.failAfterWrite = true
        XCTAssertThrowsError(try service.approve(preview(service)))
        try service.recoverPendingWrite()
        XCTAssertFalse(service.hasPendingWrite); XCTAssertEqual(client.writes, 1)
        XCTAssertTrue(try preview(service).changes.isEmpty)
    }
    @MainActor func testPreviewInvalidationAndExpiration() async throws {
        let (service, client, _) = try setup(); let proposal = try preview(service); service.invalidatePreview()
        XCTAssertThrowsError(try service.approve(proposal))
        var clock = instant; let storage = MemoryCalendarJournal()
        let timed = try AppleCalendarService(client: client, storage: storage, now: { clock })
        try timed.createCalendar(sourceID: "local", approved: true)
        let timedPreview = try preview(timed); clock = clock.addingTimeInterval(301)
        XCTAssertThrowsError(try timed.approve(timedPreview)); XCTAssertEqual(client.writes, 0)
    }
    @MainActor func testDiskJournalRoundtripAndCorruptionFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("calendar.json")
        let storage = FileCalendarJournalStore(url: url); let client = MockCalendar(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        try service.createCalendar(sourceID: "local", approved: true); try service.approve(preview(service))
        let restored = try AppleCalendarService(client: client, storage: FileCalendarJournalStore(url: url), now: { now })
        XCTAssertEqual(restored.managedEvents.count, 1)
        XCTAssertTrue(try preview(restored).changes.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try AppleCalendarService(client: client, storage: storage))
    }
    @MainActor func testDSTInstantsAndZoneSurvivePublication() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
        let client = MockCalendar(); let storage = MemoryCalendarJournal()
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        try service.createCalendar(sourceID: "local", approved: true)
        let start = ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z")!
        let session = ScheduledStudyBlock(id: "dst", taskID: "dst", title: "Study", startAt: start,
            endAt: start.addingTimeInterval(3600), sourceRecordIDs: ["source"])
        let proposal = try service.preview(blocks: [session], timeZone: "Europe/London", mode: .live, expiresAt: start)
        try service.approve(proposal)
        XCTAssertEqual(client.values[0].start, start); XCTAssertEqual(client.values[0].end.timeIntervalSince(start), 3600)
        XCTAssertEqual(client.values[0].timeZone, "Europe/London")
    }
    @MainActor func testUndoCreateUpdateAndCancellationAreApprovedAndPersisted() async throws {
        let (service, client, storage) = try setup()
        try service.approve(preview(service))
        try service.approve(preview(service, blocks: [block(7200, title: "Updated")]))
        let undoUpdate = try service.previewUndo()
        XCTAssertEqual(client.values[0].title, "Updated") // Preview is read only.
        try service.approve(undoUpdate)
        XCTAssertEqual(client.values[0].title, "Study")
        let key = try XCTUnwrap(service.managedKeys().first)
        try service.approve(preview(service, blocks: [], cancel: [key]))
        XCTAssertTrue(client.values.isEmpty)
        let now = instant
        let restarted = try AppleCalendarService(client: client, storage: storage, now: { now })
        try restarted.approve(restarted.previewUndo())
        XCTAssertEqual(client.values.count, 1)
        try restarted.approve(restarted.previewUndo())
        XCTAssertTrue(client.values.isEmpty)
        XCTAssertFalse(restarted.canUndo)
    }
    @MainActor func testUndoRefusesExternalEditsAndNewConflicts() async throws {
        let (service, client, _) = try setup()
        try service.approve(preview(service)); try service.approve(preview(service, blocks: [block(7200)]))
        var personal = client.values[0]; personal.id = "personal"; personal.marker = nil; personal.calendarID = "personal"
        personal.start = block().startAt; personal.end = block().endAt; client.values.append(personal)
        XCTAssertThrowsError(try service.previewUndo())
        client.values.removeLast(); client.values[0].title = "User edit"
        XCTAssertThrowsError(try service.previewUndo()); XCTAssertEqual(client.writes, 2)
    }
    @MainActor func testPartialBatchPreservesConfirmedChangesAndBlocksUnknownOutcome() async throws {
        let (service, client, storage) = try setup()
        client.onWrite = { client.failBeforeWrite = true }
        let proposal = try preview(service, blocks: [block(), block(7200, task: "task-2")])
        XCTAssertThrowsError(try service.approve(proposal))
        XCTAssertEqual(storage.value.records.count, 1); XCTAssertEqual(client.values.count, 1)
        XCTAssertTrue(service.hasPendingWrite); XCTAssertThrowsError(try preview(service))
        XCTAssertEqual(storage.value.pending?.after?.title, "Study")
    }
    @MainActor func testConflictAppearingDuringBatchStopsRemainingWrites() async throws {
        let (service, client, _) = try setup()
        let second = block(7200, task: "task-2")
        client.onWrite = {
            client.values.append(AppleCalendarEvent(id: "new-meeting", calendarID: "personal", marker: nil,
                title: "Meeting", start: second.startAt, end: second.endAt, timeZone: "Europe/London"))
        }
        XCTAssertThrowsError(try service.approve(preview(service, blocks: [block(), second])))
        XCTAssertEqual(client.writes, 1); XCTAssertEqual(service.managedEvents.count, 1)
        XCTAssertFalse(service.hasPendingWrite)
    }
    @MainActor func testCancellationCommitThenErrorCanBeRecoveredAndUndone() async throws {
        let (service, client, _) = try setup(); try service.approve(preview(service))
        let key = try XCTUnwrap(service.managedKeys().first); client.failAfterWrite = true
        XCTAssertThrowsError(try service.approve(preview(service, blocks: [], cancel: [key])))
        try service.recoverPendingWrite(); XCTAssertTrue(service.managedEvents.isEmpty)
        client.failAfterWrite = false
        try service.approve(service.previewUndo()); XCTAssertEqual(client.values.count, 1)
    }
    @MainActor func testFailedUpdateCanReconcileUnchangedBeforeState() async throws {
        let (service, client, _) = try setup(); try service.approve(preview(service))
        client.failBeforeWrite = true
        XCTAssertThrowsError(try service.approve(preview(service, blocks: [block(7200)])))
        try service.recoverPendingWrite()
        XCTAssertFalse(service.hasPendingWrite); XCTAssertEqual(service.managedEvents[0].start, block().startAt)
        XCTAssertEqual(client.writes, 1)
    }
    @MainActor func testCalendarAwarePlanningAvoidsBusyTimeAndDemoDoesNotReadCalendar() async throws {
        let (service, client, _) = try setup()
        let source = SourceRecord(id: "source", provider: "Canvas", externalID: "assignment", retrievedAt: instant)
        let deadline = AcademicItem(id: "assignment", title: "Work", startsAt: instant.addingTimeInterval(86400 * 2),
            endsAt: instant.addingTimeInterval(86400 * 2), timeZoneIdentifier: "Europe/London", kind: .deadline,
            verification: .verified, sourceRecordIDs: [source.id])
        let dataset = AcademicDataset(items: [deadline], sources: [source])
        let baseline = try CalendarAwarePlanning.makePlan(dataset: dataset, progress: [:], availability: AvailabilitySettings(), now: instant, calendar: nil)
        let first = try XCTUnwrap(baseline.schedule.blocks.first)
        client.values = [AppleCalendarEvent(id: "meeting", calendarID: "personal", marker: nil, title: "Meeting",
            start: first.startAt, end: first.endAt, timeZone: "Europe/London")]
        let result = try CalendarAwarePlanning.makePlan(dataset: dataset, progress: [:], availability: AvailabilitySettings(), now: instant, calendar: service)
        XCTAssertFalse(result.schedule.blocks.isEmpty)
        XCTAssertFalse(result.schedule.blocks.contains { $0.startAt < first.endAt && $0.endAt > first.startAt })
        let reads = client.reads; client.access = .denied
        let demo = AcademicDataset(mode: .demo, items: [deadline], sources: [source])
        XCTAssertNoThrow(try CalendarAwarePlanning.makePlan(dataset: demo, progress: [:], availability: AvailabilitySettings(), now: instant, calendar: service))
        XCTAssertEqual(client.reads, reads)
        XCTAssertThrowsError(try CalendarAwarePlanning.makePlan(dataset: dataset, progress: [:], availability: AvailabilitySettings(), now: instant, calendar: service))
    }

    @MainActor func testExpirationDuringBatchStopsRemainingWrites() async throws {
        var clock = instant; let client = MockCalendar(); let storage = MemoryCalendarJournal()
        let service = try AppleCalendarService(client: client, storage: storage, now: { clock })
        try service.createCalendar(sourceID: "local", approved: true)
        let proposal = try preview(service, blocks: [block(), block(7200, task: "later")])
        client.onWrite = { clock = clock.addingTimeInterval(301) }
        XCTAssertThrowsError(try service.approve(proposal)) { XCTAssertEqual($0 as? AppleCalendarError, .stalePreview) }
        XCTAssertEqual(client.writes, 1); XCTAssertFalse(service.hasPendingWrite)
    }

    @MainActor func testMergedCanvasOutlookAndCalendarPlanningPreservesLocalState() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("planner.sqlite").path
        let db = try LocalDatabase(path: path)
        let due = now.addingTimeInterval(3 * 86400)
        let sources = ["active", "completed", "overdue"].map { id in
            SourceRecord(id: id, provider: "Canvas", externalID: id, retrievedAt: now,
                displayTitle: id, assignmentDetails: ImportedAssignmentDetails(dueAt: id == "overdue" ? now : due))
        }
        let imported = CanvasImportResult(sourceRecords: sources, academicItems: [])
        try db.importCanvas(imported, successfulAt: now)
        let completed = AssignmentProgress(assignmentID: "completed", status: .completed, updatedAt: now)
        try db.save(completed)
        let demo = SourceRecord(id: "source-canvas-demo", provider: "Canvas (sample)", externalID: "demo", retrievedAt: now)
        try db.save(demo)
        // This demonstration commitment would consume the entire real planning window if scopes leaked.
        try db.save(AcademicItem(id: "demo-busy", title: "Sample commitment", startsAt: now, endsAt: due,
            timeZoneIdentifier: "Europe/London", kind: .classSession, verification: .verified,
            sourceRecordIDs: [demo.id], isProtected: true))
        func dataset(_ database: LocalDatabase) throws -> AcademicDataset {
            AcademicDataset(items: try database.items(), sources: try database.sourceRecords())
        }
        let availability = AvailabilitySettings(timeZoneIdentifier: "Europe/London")
        let baseline = try CalendarAwarePlanning.makePlan(dataset: dataset(db), progress: db.assignmentProgress(),
            availability: availability, now: now, calendar: nil)
        let first = try XCTUnwrap(baseline.schedule.blocks.first)
        let account = OutlookAccount(profileID: "mock-user", clientID: "11111111-1111-1111-1111-111111111111",
            label: "Fixture", address: "fixture@example.invalid", now: now)
        var state = OutlookState(); state.accounts = [account]; try db.save(state)
        let mail = SourceRecord(id: "mock-mail", provider: "Outlook", externalID: "mock-message", retrievedAt: now)
        let proposal = EmailProposal(id: "mock-proposal", accountID: account.id, messageID: "mock-message",
            sourceID: mail.id, title: "Tutorial", kind: .tutorial, date: first.startAt,
            durationMinutes: Int(first.endAt.timeIntervalSince(first.startAt) / 60), confidence: 0.9,
            evidence: "Synthetic tutorial at the first proposed session")
        try db.importOutlook(OutlookSyncBatch(account: account, proposals: [proposal], sources: [mail],
            messages: [:], removedMessageIDs: [], notices: []))
        let pending = try CalendarAwarePlanning.makePlan(dataset: dataset(db), progress: db.assignmentProgress(),
            availability: availability, now: now, calendar: nil)
        XCTAssertEqual(pending.schedule.blocks.first?.startAt, first.startAt, "Unapproved mail must not block time")
        try db.decideOutlook(ids: [proposal.id], decision: .accepted)
        let reviewed = try CalendarAwarePlanning.makePlan(dataset: dataset(db), progress: db.assignmentProgress(),
            availability: availability, now: now, calendar: nil)
        let next = try XCTUnwrap(reviewed.schedule.blocks.first)
        let client = MockCalendar(); let storage = MemoryCalendarJournal()
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        try service.createCalendar(sourceID: "local", approved: true)
        client.values = [AppleCalendarEvent(id: "personal-fixture", calendarID: "personal", marker: nil,
            title: "Synthetic personal commitment", start: next.startAt, end: next.endAt, timeZone: "Europe/London")]
        let combined = try CalendarAwarePlanning.makePlan(dataset: dataset(db), progress: db.assignmentProgress(),
            availability: availability, now: now, calendar: service)
        XCTAssertFalse(combined.schedule.blocks.isEmpty)
        for block in combined.schedule.blocks {
            XCTAssertEqual(block.sourceRecordIDs, ["active"], "Completed, overdue and demo work must stay excluded")
            XCTAssertFalse(block.startAt < first.endAt && block.endAt > first.startAt, "Approved Outlook commitment")
            XCTAssertFalse(block.startAt < next.endAt && block.endAt > next.startAt, "Calendar commitment")
        }
        let preview = try service.preview(blocks: combined.schedule.blocks, timeZone: "Europe/London", mode: .live,
            expiresAt: try XCTUnwrap(combined.expiresAt))
        XCTAssertEqual(client.writes, 0)
        try service.approve(preview)
        XCTAssertEqual(service.managedEvents.count, combined.schedule.blocks.count)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.values.first(where: { $0.id == "personal-fixture" })?.title, "Synthetic personal commitment")
        try db.importCanvas(imported, successfulAt: now.addingTimeInterval(60))
        let reopened = try LocalDatabase(path: path)
        XCTAssertEqual(try reopened.assignmentProgress()["completed"], completed)
        XCTAssertEqual(try reopened.outlookState().proposals.first?.decision, .accepted)
        XCTAssertEqual(try dataset(reopened).sources.count, 4)
        XCTAssertEqual(try reopened.sourceRecords().count, 5, "Demo and real records remain stored")
        try reopened.save(AssignmentProgress(assignmentID: "active", status: .completed, updatedAt: now))
        let finished = try CalendarAwarePlanning.makePlan(dataset: dataset(reopened), progress: reopened.assignmentProgress(),
            availability: availability, now: now, calendar: service)
        XCTAssertTrue(finished.schedule.blocks.isEmpty)
        XCTAssertEqual(service.managedEvents.count, combined.schedule.blocks.count, "Completion must not silently cancel published events")
    }

    @MainActor func testTimelineKeepsPersonalTitlesAndExpandsAllDayAndRecurringOccurrences() throws {
        let client = MockCalendar(); let storage = MemoryCalendarJournal(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        let interval = DateInterval(start: instant, end: instant.addingTimeInterval(4 * 86400))
        let duplicateStart = instant.addingTimeInterval(3600)
        client.values = [
            AppleCalendarEvent(id: "duplicate", calendarID: "personal", marker: nil, title: "Linear Algebra",
                start: duplicateStart, end: duplicateStart.addingTimeInterval(3600), timeZone: "Europe/London"),
            AppleCalendarEvent(id: "all-day", calendarID: "personal", marker: nil, title: "Private leave",
                start: instant.addingTimeInterval(86400), end: instant.addingTimeInterval(2 * 86400), timeZone: "Europe/London", isAllDay: true),
            AppleCalendarEvent(id: "recurring", calendarID: "personal", marker: nil, title: "Private recurring",
                start: instant.addingTimeInterval(2 * 86400), end: instant.addingTimeInterval(2 * 86400 + 1800), timeZone: "Europe/London"),
            AppleCalendarEvent(id: "recurring", calendarID: "personal", marker: nil, title: "Private recurring",
                start: instant.addingTimeInterval(3 * 86400), end: instant.addingTimeInterval(3 * 86400 + 1800), timeZone: "Europe/London"),
            AppleCalendarEvent(id: "free", calendarID: "personal", marker: nil, title: "Free availability",
                start: instant.addingTimeInterval(7200), end: instant.addingTimeInterval(10_800), timeZone: "Europe/London", isBusy: false)
        ]
        let projected = try service.timelineEvents(in: interval)
        XCTAssertEqual(projected.count, 4)
        XCTAssertEqual(projected.map(\.title), ["Linear Algebra", "Private leave", "Private recurring", "Private recurring"])
        XCTAssertTrue(projected.allSatisfy { $0.source == .personal })
        XCTAssertTrue(try XCTUnwrap(projected.first { $0.id.contains("all-day") }).isAllDay)
        XCTAssertEqual(projected.filter { $0.id.contains("recurring") }.count, 2)
        XCTAssertTrue(storage.value.records.isEmpty, "Reading personal events must not persist ownership or content")

        let source = SourceRecord(id: "canvas-source", provider: "Canvas", externalID: "course", retrievedAt: now)
        let imported = AcademicItem(id: "canvas-event", title: "Linear Algebra", startsAt: duplicateStart,
            endsAt: duplicateStart.addingTimeInterval(3600), timeZoneIdentifier: "Europe/London", kind: .classSession,
            verification: .verified, sourceRecordIDs: [source.id], isProtected: true)
        let unified = UnifiedTimeline.events(academicItems: [imported], sources: [source], calendarEvents: projected)
        XCTAssertEqual(unified.filter { $0.source == .appleCalendar && $0.start == duplicateStart }.count, 0)
        XCTAssertEqual(unified.filter { $0.source == .canvas && $0.start == duplicateStart }.count, 1)
        XCTAssertTrue(unified.filter { $0.source == .appleCalendar }.allSatisfy(\.isProtected))
    }

    @MainActor func testTimelineUsesLocalFallbackForMissingPersonalTitleWithoutPersistingIt() throws {
        let client = MockCalendar(); let storage = MemoryCalendarJournal(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        let interval = DateInterval(start: instant, end: instant.addingTimeInterval(3600))
        client.values = [
            AppleCalendarEvent(id: "untitled", calendarID: "personal", marker: nil, title: "   ",
                start: instant, end: instant.addingTimeInterval(1800), timeZone: "Europe/London")
        ]

        let projected = try service.timelineEvents(in: interval)

        XCTAssertEqual(projected.map(\.title), ["Untitled Calendar event"])
        XCTAssertEqual(projected.first?.source, .personal)
        XCTAssertTrue(storage.value.records.isEmpty)
        XCTAssertEqual(client.writes, 0)
    }

    @MainActor func testStartupLoaderUsesPersistedFullAccessWithoutRequestingPermission() throws {
        let client = MockCalendar(); let storage = MemoryCalendarJournal(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        let interval = DateInterval(start: instant, end: instant.addingTimeInterval(3600))
        client.values = [
            AppleCalendarEvent(id: "persisted-access", calendarID: "personal", marker: nil, title: "Research meeting",
                start: instant, end: instant.addingTimeInterval(1800), timeZone: "Europe/London")
        ]

        let loaded = try AppleCalendarTimelineLoader.eventsIfAuthorized(service: service, in: interval)

        XCTAssertEqual(loaded?.map(\.title), ["Research meeting"])
        XCTAssertEqual(client.reads, 1)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.writes, 0)
        XCTAssertTrue(storage.value.records.isEmpty)
    }

    @MainActor func testStartupLoaderDoesNotReadOrPromptWhenPermissionIsRevoked() throws {
        let client = MockCalendar(); client.access = .denied
        let service = try AppleCalendarService(client: client, storage: MemoryCalendarJournal(), now: { self.instant })
        let interval = DateInterval(start: instant, end: instant.addingTimeInterval(3600))

        let loaded = try AppleCalendarTimelineLoader.eventsIfAuthorized(service: service, in: interval)

        XCTAssertNil(loaded)
        XCTAssertEqual(client.reads, 0)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.writes, 0)
    }

    @MainActor func testStartupLoaderRefreshesOnlyTheNewActiveTimelineRange() throws {
        let client = MockCalendar(); let storage = MemoryCalendarJournal(); let now = instant
        let service = try AppleCalendarService(client: client, storage: storage, now: { now })
        let today = DateInterval(start: instant, end: instant.addingTimeInterval(86400))
        let tomorrow = DateInterval(start: today.end, end: today.end.addingTimeInterval(86400))
        client.values = [
            AppleCalendarEvent(id: "today", calendarID: "personal", marker: nil, title: "Today",
                start: instant.addingTimeInterval(3600), end: instant.addingTimeInterval(5400), timeZone: "Europe/London"),
            AppleCalendarEvent(id: "tomorrow", calendarID: "personal", marker: nil, title: "Tomorrow",
                start: today.end.addingTimeInterval(3600), end: today.end.addingTimeInterval(5400), timeZone: "Europe/London")
        ]

        let first = try AppleCalendarTimelineLoader.eventsIfAuthorized(service: service, in: today)
        let second = try AppleCalendarTimelineLoader.eventsIfAuthorized(service: service, in: tomorrow)

        XCTAssertEqual(first?.map(\.title), ["Today"])
        XCTAssertEqual(second?.map(\.title), ["Tomorrow"])
        XCTAssertEqual(client.reads, 2)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(storage.value.records.isEmpty)
    }

    @MainActor func testTimelineShowsOnlyOwnedManagedSessionsAndRefreshesOnCalendarChange() throws {
        let (service, client, storage) = try setup()
        try service.approve(preview(service))
        let range = DateInterval(start: instant, end: instant.addingTimeInterval(86400))
        let first = try service.timelineEvents(in: range)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].source, .managed)
        XCTAssertEqual(first[0].title, "Study")
        XCTAssertEqual(storage.value.records.count, 1)

        var changes = 0
        let observer = try service.observeChanges { changes += 1 }
        client.notifyCalendarChanged()
        XCTAssertEqual(changes, 1)
        observer.cancel()
        client.notifyCalendarChanged()
        XCTAssertEqual(changes, 1)

        var personal = client.values[0]
        personal.id = "personal-in-managed-calendar"; personal.marker = nil; personal.title = "Personal title"
        client.values.append(personal)
        let refreshed = try service.timelineEvents(in: range)
        XCTAssertEqual(refreshed.filter { $0.source == .managed }.count, 1)
        XCTAssertEqual(refreshed.filter { $0.source == .personal }.map(\.title), ["Personal title"])
        XCTAssertEqual(storage.value.records.count, 1, "A personal event never gains managed ownership")
    }

    func testExistingOwnershipJournalDecodesWithoutAllDayTimelineMetadata() throws {
        let oldJournal: [String: Any] = [
            "calendarID": "managed",
            "records": ["slot": [
                "id": "event", "calendarID": "managed", "marker": "marker", "title": "Study",
                "start": instant.timeIntervalSinceReferenceDate,
                "end": instant.addingTimeInterval(3600).timeIntervalSinceReferenceDate,
                "timeZone": "Europe/London", "isBusy": true, "isSafeToModify": true
            ]],
            "pending": NSNull(), "pendingIsUndo": false, "undoHistory": [], "audit": []
        ]
        let data = try JSONSerialization.data(withJSONObject: oldJournal)
        XCTAssertFalse(try XCTUnwrap(JSONDecoder().decode(CalendarJournal.self, from: data).records["slot"]).isAllDay)
    }

}
