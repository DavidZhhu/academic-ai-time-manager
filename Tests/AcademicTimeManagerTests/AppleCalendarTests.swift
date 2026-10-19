import Foundation
import XCTest
@testable import AcademicCore

@MainActor private final class MockCalendar: AppleCalendarClient {
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

}
