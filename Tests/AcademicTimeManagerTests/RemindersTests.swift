import Foundation
import XCTest
@testable import AcademicCore

/// Synthetic client. Never touches EventKit or any real Reminders data.
/// A manually advanced replacement for `Task.sleep`: a sleeper suspends until `advance` or cancellation.
private final class ManualSleeper: Sendable {
    private struct Waiter { let id: Int; let duration: Duration; let continuation: CheckedContinuation<Void, Error> }
    private struct Arrival { let duration: Duration; let count: Int; let continuation: CheckedContinuation<Void, Never> }
    private struct State {
        var waiters: [Waiter] = []
        var cancelledBeforeStart: Set<Int> = []
        var arrivals: [Arrival] = []
        var nextID = 0
        func count(of duration: Duration) -> Int { waiters.filter { $0.duration == duration }.count }
    }
    private let state = NSLock_Box()

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { s -> Int in defer { s.nextID += 1 }; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let ready: [Arrival]? = state.withLock { s in
                    if s.cancelledBeforeStart.remove(id) != nil { return nil }
                    s.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    let snapshot = s
                    let ready = snapshot.arrivals.filter { snapshot.count(of: $0.duration) >= $0.count }
                    s.arrivals.removeAll { a in snapshot.count(of: a.duration) >= a.count }
                    return ready
                }
                if let ready { ready.forEach { $0.continuation.resume() } }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { s in
                guard let w = s.waiters.first(where: { $0.id == id }) else { s.cancelledBeforeStart.insert(id); return nil }
                s.waiters.removeAll { $0.id == id }
                return w
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func sleeping(_ duration: Duration) -> Int { state.withLock { $0.count(of: duration) } }

    /// Resumes every sleeper waiting for `duration`.
    func advance(_ duration: Duration) {
        let due: [Waiter] = state.withLock { s in
            let due = s.waiters.filter { $0.duration == duration }
            s.waiters.removeAll { $0.duration == duration }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    func waitUntilSleeping(_ duration: Duration, count target: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let satisfied = state.withLock { s -> Bool in
                if s.count(of: duration) >= target { return true }
                s.arrivals.append(Arrival(duration: duration, count: target, continuation: continuation))
                return false
            }
            if satisfied { continuation.resume() }
        }
    }

    private final class NSLock_Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()
        func withLock<R>(_ body: (inout State) -> R) -> R { lock.withLock { body(&value) } }
    }
}

@MainActor private final class MockReminders: RemindersClient {
    fileprivate final class Observation: AppleCalendarChangeObservation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var access: RemindersAccess = .fullAccess
    var listValues: [ReminderListInfo] = []
    var values: [ReminderItem] = []
    var permissionRequests = 0
    var listReads = 0
    var itemReads = 0
    var failReads = false
    var revokeDuringRead = false
    var grantOnRequest = true
    var observers = 0
    var changeHandler: (@MainActor () -> Void)?
    var lastObservation: Observation?

    func requestAccess() async throws {
        permissionRequests += 1
        if grantOnRequest { access = .fullAccess } else { access = .denied; throw RemindersError.permission }
    }
    func lists() throws -> [ReminderListInfo] {
        listReads += 1
        if access != .fullAccess { throw RemindersError.permission }
        return listValues
    }
    func reminders(in listIDs: [String]) async throws -> [ReminderItem] {
        itemReads += 1
        await Task.yield(); await Task.yield()
        if failReads { throw RemindersError.unavailable }
        if revokeDuringRead { access = .denied }
        return values.filter { listIDs.contains($0.listID) }
    }
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleCalendarChangeObservation {
        observers += 1
        let observation = Observation(); lastObservation = observation
        changeHandler = { if !observation.cancelled { handler() } }
        return observation
    }
}

@MainActor final class RemindersTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let study = ReminderListInfo(id: "L1", title: "Study", sourceID: "S1", sourceTitle: "iCloud")
    private let home = ReminderListInfo(id: "L2", title: "Home", sourceID: "S2", sourceTitle: "On My Mac")

    private func item(_ id: String, list: String = "L1", title: String = "Task", due: Date? = nil, timed: Bool = true,
                      priority: ReminderPriority = .none, done: Bool = false, parent: String? = nil,
                      ext: String? = nil, modified: Date? = nil, recurring: Bool = false) -> ReminderItem {
        ReminderItem(id: id, externalID: ext, listID: list, title: title,
                     due: due.map { ReminderDue(date: $0, hasTime: timed) }, priority: priority,
                     isCompleted: done, parentID: parent, isRecurring: recurring, lastModified: modified)
    }
    private func service(_ client: MockReminders) -> RemindersSyncService { RemindersSyncService(client: client, now: { self.now }) }

    // MARK: Permissions

    func testSyncNeverPromptsAndPurgesWhenNotAuthorized() async {
        let client = MockReminders(); client.access = .notDetermined
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertNil(report)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.listReads, 0)
        XCTAssertEqual(sut.state, .notAuthorized(.notDetermined))
        XCTAssertTrue(sut.snapshot.items.isEmpty)
    }

    func testExplicitRequestGrantsAndDenialThrows() async throws {
        let client = MockReminders(); client.access = .notDetermined
        let sut = service(client)
        try await sut.requestAccess()
        XCTAssertEqual(client.permissionRequests, 1)
        let denied = MockReminders(); denied.access = .notDetermined; denied.grantOnRequest = false
        do { try await service(denied).requestAccess(); XCTFail("expected permission error") }
        catch { XCTAssertEqual(error as? RemindersError, .permission) }
    }

    func testWriteOnlyAndRestrictedAreTreatedAsUnauthorized() async {
        for access in [RemindersAccess.writeOnly, .restricted, .denied] {
            let client = MockReminders(); client.access = access
            let sut = service(client)
            await sut.syncIfAuthorized()
            XCTAssertEqual(sut.state, .notAuthorized(access))
            XCTAssertEqual(client.listReads, 0)
        }
    }

    func testRevocationAfterSyncClearsReminderContent() async {
        let client = MockReminders()
        client.listValues = [study]; client.values = [item("a")]
        let sut = service(client)
        await sut.syncIfAuthorized()
        XCTAssertEqual(sut.snapshot.items.count, 1)
        client.access = .denied
        await sut.syncIfAuthorized()
        XCTAssertEqual(sut.snapshot, .empty)
        XCTAssertEqual(sut.state, .notAuthorized(.denied))
    }

    func testRevocationDuringReadDiscardsResult() async {
        let client = MockReminders()
        client.listValues = [study]; client.values = [item("a")]; client.revokeDuringRead = true
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertNil(report)
        XCTAssertTrue(sut.snapshot.items.isEmpty)
        XCTAssertEqual(sut.state, .notAuthorized(.denied))
    }

    // MARK: Read-only synchronisation

    func testImportsAllListsWithFieldsAndSourceInformation() async {
        let client = MockReminders()
        client.listValues = [study, home]
        let url = URL(string: "https://example.com/reading")!
        client.values = [
            ReminderItem(id: "a", externalID: "ext-a", listID: "L1", title: "Read chapter", notes: "pp. 1–20",
                         due: ReminderDue(date: date(2026, 11, 2), hasTime: true, timeZoneIdentifier: "Europe/London"),
                         priority: .high, isCompleted: false, url: url, parentID: nil),
            item("b", list: "L2", title: "Buy milk", done: true)
        ]
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.listCount, 2)
        XCTAssertEqual(report?.itemCount, 2)
        let a = sut.snapshot.items.first { $0.id == "a" }
        XCTAssertEqual(a?.notes, "pp. 1–20")
        XCTAssertEqual(a?.externalID, "ext-a")
        XCTAssertEqual(a?.priority, .high)
        XCTAssertEqual(a?.url, url)
        XCTAssertEqual(a?.due?.timeZoneIdentifier, "Europe/London")
        XCTAssertEqual(sut.snapshot.list("L2")?.sourceTitle, "On My Mac")
        XCTAssertTrue(sut.snapshot.items.first { $0.id == "b" }!.isCompleted)
        XCTAssertEqual(sut.state, .synced)
        XCTAssertEqual(sut.snapshot.syncedAt, now)
    }

    func testRepeatedSyncIsIdempotent() async {
        let client = MockReminders()
        client.listValues = [study]; client.values = [item("a"), item("b")]
        let sut = service(client)
        await sut.syncIfAuthorized()
        let first = sut.snapshot
        let second = await sut.syncIfAuthorized()
        XCTAssertEqual(sut.snapshot, first)
        XCTAssertEqual(second?.removedItems, 0)
    }

    func testOnlyUnsupportedURLSchemesAreDropped() {
        XCTAssertNil(ReminderItem(id: "x", listID: "L", title: "t", url: URL(string: "file:///etc/passwd")).url)
        XCTAssertNil(ReminderItem(id: "x", listID: "L", title: "t", url: URL(string: "javascript:alert(1)")).url)
        XCTAssertNotNil(ReminderItem(id: "x", listID: "L", title: "t", url: URL(string: "HTTPS://example.com")).url)
    }

    func testPriorityMapping() {
        XCTAssertEqual(ReminderPriority(eventKitValue: 0), .none)
        XCTAssertEqual(ReminderPriority(eventKitValue: 1), .high)
        XCTAssertEqual(ReminderPriority(eventKitValue: 4), .high)
        XCTAssertEqual(ReminderPriority(eventKitValue: 5), .medium)
        XCTAssertEqual(ReminderPriority(eventKitValue: 9), .low)
        XCTAssertEqual(ReminderPriority(eventKitValue: 42), .none)
    }

    func testDueComponentsDistinguishDateOnlyFromTimed() {
        var dateOnly = DateComponents(year: 2026, month: 11, day: 2)
        dateOnly.calendar = calendar
        let day = ReminderDue(components: dateOnly)
        XCTAssertEqual(day?.hasTime, false)
        XCTAssertEqual(day?.date, calendar.startOfDay(for: date(2026, 11, 2)))
        var timed = DateComponents(year: 2026, month: 11, day: 2, hour: 15, minute: 30)
        timed.calendar = calendar; timed.timeZone = TimeZone(identifier: "America/New_York")
        let value = ReminderDue(components: timed)
        XCTAssertEqual(value?.hasTime, true)
        XCTAssertEqual(value?.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(value?.date, ISO8601DateFormatter().date(from: "2026-11-02T20:30:00Z"))
        XCTAssertNil(ReminderDue(components: DateComponents(hour: 9)))
    }

    // MARK: Deduplication, deletion, missing lists, recurrence, failures

    func testDuplicatesCollapseKeepingNewestAndStableAcrossOrder() async {
        let older = item("a1", title: "Old", ext: "same", modified: date(2026, 10, 1))
        let newer = item("a2", title: "New", ext: "same", modified: date(2026, 10, 2))
        let otherList = item("a3", list: "L2", title: "Other list", ext: "same")
        for order in [[older, newer, otherList], [otherList, newer, older]] {
            let client = MockReminders(); client.listValues = [study, home]; client.values = order
            let sut = service(client)
            let report = await sut.syncIfAuthorized()
            XCTAssertEqual(report?.duplicatesCollapsed, 1)
            XCTAssertEqual(sut.snapshot.items.map(\.id), ["a2", "a3"]) // same external ID in a different list is distinct
        }
    }

    func testItemsWithoutExternalIDDeduplicateByLocalID() async {
        let client = MockReminders(); client.listValues = [study]
        client.values = [item("a"), item("a"), item("b")]
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.itemCount, 2)
        XCTAssertEqual(report?.duplicatesCollapsed, 1)
    }

    func testDeletedReminderAndMissingListAreRemovedAndCounted() async {
        let client = MockReminders()
        client.listValues = [study, home]; client.values = [item("a"), item("b"), item("c", list: "L2")]
        let sut = service(client)
        await sut.syncIfAuthorized()
        client.values = [item("a"), item("c", list: "L2")]       // b deleted
        var report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.removedItems, 1)
        XCTAssertEqual(sut.snapshot.items.map(\.id), ["a", "c"])
        client.listValues = [study]                                // Home list removed; its reminder may linger in a read
        report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.removedLists, 1)
        XCTAssertEqual(sut.snapshot.items.map(\.id), ["a"])
        XCTAssertNil(sut.snapshot.list("L2"))
    }

    func testRecurringReminderIsOneEntryAndFlagged() async {
        let client = MockReminders(); client.listValues = [study]
        client.values = [item("r", title: "Weekly review", due: date(2026, 11, 4), recurring: true)]
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.recurringCount, 1)
        XCTAssertEqual(sut.snapshot.items.count, 1)
        XCTAssertTrue(sut.snapshot.items[0].isRecurring)
    }

    func testReadFailureKeepsPreviousSnapshotAndRecovers() async {
        let client = MockReminders(); client.listValues = [study]; client.values = [item("a")]
        let sut = service(client)
        await sut.syncIfAuthorized()
        client.failReads = true
        let failed = await sut.syncIfAuthorized()
        XCTAssertNil(failed)
        XCTAssertEqual(sut.snapshot.items.map(\.id), ["a"])
        if case .failed = sut.state {} else { XCTFail("expected failed state, got \(sut.state)") }
        client.failReads = false; client.values = [item("a"), item("b")]
        await sut.syncIfAuthorized()
        XCTAssertEqual(sut.state, .synced)
        XCTAssertEqual(sut.snapshot.items.count, 2)
    }

    func testEmptyStoreIsAValidSync() async {
        let client = MockReminders()
        let sut = service(client)
        let report = await sut.syncIfAuthorized()
        XCTAssertEqual(report?.itemCount, 0)
        XCTAssertEqual(sut.state, .synced)
    }

    func testOverlappingSyncIsSkipped() async {
        let client = MockReminders(); client.listValues = [study]; client.values = [item("a")]
        let sut = service(client)
        async let first = sut.syncIfAuthorized()
        async let second = sut.syncIfAuthorized()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(client.itemReads, 1)
    }

    // MARK: Monitoring (launch sync, change notifications, periodic refresh)

    func testMonitoringSyncsOnLaunchOnChangeNotificationAndPeriodically() async throws {
        let client = MockReminders(); client.listValues = [study]; client.values = [item("a")]
        let clock = ManualSleeper()
        let sut = RemindersSyncService(client: client, now: { self.now }, sleep: { try await clock.sleep($0) })
        var updates = syncCompletions(of: sut).makeAsyncIterator()
        let interval = Duration.milliseconds(400), debounce = Duration.milliseconds(20)
        sut.startMonitoring(interval: interval, debounce: debounce)

        await updates.next()                                // launch sync
        XCTAssertEqual(client.itemReads, 1)
        XCTAssertEqual(client.observers, 1)
        await clock.waitUntilSleeping(interval, count: 1)

        client.values = [item("a"), item("b")]
        for _ in 0..<5 { client.changeHandler?() }          // a burst coalesces into one pending debounce
        await clock.waitUntilSleeping(debounce, count: 1)
        XCTAssertEqual(clock.sleeping(debounce), 1)
        clock.advance(debounce)
        await updates.next()
        XCTAssertEqual(client.itemReads, 2)
        XCTAssertEqual(sut.snapshot.items.count, 2)

        await clock.waitUntilSleeping(interval, count: 1)
        clock.advance(interval)                             // periodic refresh
        await updates.next()
        XCTAssertEqual(client.itemReads, 3)

        await clock.waitUntilSleeping(interval, count: 1)
        sut.stopMonitoring()
        XCTAssertTrue(client.lastObservation!.cancelled)
        XCTAssertEqual(clock.sleeping(interval), 0)
        client.changeHandler?()
        XCTAssertEqual(clock.sleeping(debounce), 0)         // nothing can schedule another sync
        XCTAssertEqual(client.itemReads, 3)
    }

    /// Emits once per completed sync so tests await events instead of wall-clock time.
    private func syncCompletions(of service: RemindersSyncService) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        service.onUpdate = { continuation.yield() }
        return stream
    }

    func testRevocationStopsObservation() async throws {
        let client = MockReminders(); client.listValues = [study]
        let sut = service(client)
        sut.startMonitoring(interval: .seconds(60), debounce: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(client.lastObservation!.cancelled)
        client.access = .denied
        client.changeHandler?()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(client.lastObservation!.cancelled)
        XCTAssertEqual(sut.state, .notAuthorized(.denied))
        sut.stopMonitoring()
    }

    // MARK: Task presentation

    func testUpcomingSeparatesOverdueAndIgnoresCompletedUndatedAndFarFuture() {
        let today = calendar.startOfDay(for: now)
        let items = [
            item("late", due: now.addingTimeInterval(-3600)),
            item("soon", due: now.addingTimeInterval(86400)),
            item("far", due: calendar.date(byAdding: .day, value: 30, to: today)!),
            item("done", due: now.addingTimeInterval(7200), done: true),
            item("undated"),
            item("dayonly-today", due: today, timed: false),
            item("dayonly-yesterday", due: calendar.date(byAdding: .day, value: -1, to: today)!, timed: false)
        ]
        let result = RemindersPresentation.upcoming(items, now: now, calendar: calendar)
        XCTAssertEqual(result.overdue.map(\.id), ["dayonly-yesterday", "late"])
        XCTAssertEqual(Set(result.upcoming.map(\.id)), ["soon", "dayonly-today"])
    }

    func testDateOnlyReminderIsNotOverdueDuringItsDay() {
        let today = calendar.startOfDay(for: now)
        XCTAssertFalse(RemindersPresentation.isOverdue(item("t", due: today, timed: false), now: now, calendar: calendar))
        XCTAssertTrue(RemindersPresentation.isOverdue(item("t", due: now.addingTimeInterval(-1)), now: now, calendar: calendar))
        XCTAssertFalse(RemindersPresentation.isOverdue(item("t", due: now.addingTimeInterval(-1), done: true), now: now, calendar: calendar))
    }

    func testTreeNestsSubtasksAndNeverLosesOrphansOrCycles() {
        let items = [
            item("p", title: "Parent"), item("c1", title: "Child 1", parent: "p"), item("c2", title: "Child 2", parent: "p"),
            item("orphan", title: "Orphan", parent: "missing"),
            item("x", title: "X", parent: "y"), item("y", title: "Y", parent: "x"),   // cycle
            item("self", title: "Self", parent: "self"),
            item("other", list: "L2", title: "Other")
        ]
        let nodes = RemindersPresentation.tree(items, listID: "L1")
        let parent = nodes.first { $0.id == "p" }
        XCTAssertEqual(Set(parent?.children.map(\.id) ?? []), ["c1", "c2"])
        let flattened = nodes.flatMap { [$0] + $0.children }
        XCTAssertEqual(Set(flattened.map(\.id)), ["p", "c1", "c2", "orphan", "x", "y", "self"])
        XCTAssertEqual(flattened.count, 7)
        XCTAssertFalse(flattened.contains { $0.id == "other" })
    }

    func testListOrderPutsOpenDatedHighPriorityFirst() {
        let nodes = RemindersPresentation.tree([
            item("done", done: true), item("undated"), item("later", due: date(2026, 12, 1)),
            item("sooner-low", due: date(2026, 11, 1), priority: .low), item("sooner-high", due: date(2026, 11, 1), priority: .high)
        ])
        XCTAssertEqual(nodes.map(\.id), ["sooner-high", "sooner-low", "later", "undated", "done"])
    }

    func testDueDescriptionAndCounts() {
        let late = item("a", due: now.addingTimeInterval(-3600))
        XCTAssertTrue(RemindersPresentation.dueDescription(late, now: now, calendar: calendar).hasPrefix("Overdue"))
        XCTAssertEqual(RemindersPresentation.dueDescription(item("b"), now: now), "No due date")
        XCTAssertEqual(RemindersPresentation.openCount([late, item("c", done: true), item("d", list: "L2")], listID: "L1"), 1)
    }

    // MARK: Calendar markers are not busy time

    func testMarkersSelectDueDatesInRangeAndKeepCompletedFlag() {
        let items = [item("in", title: "Essay", due: date(2026, 11, 3)), item("done", due: date(2026, 11, 3), done: true),
                     item("out", due: date(2026, 12, 3)), item("none")]
        let interval = DateInterval(start: date(2026, 11, 1, 0), end: date(2026, 11, 8, 0))
        let markers = RemindersPresentation.markers(items: items, lists: [study], in: interval)
        XCTAssertEqual(Set(markers.map(\.reminderID)), ["in", "done"])
        XCTAssertEqual(markers.first { $0.reminderID == "in" }?.listTitle, "Study")
        XCTAssertTrue(markers.first { $0.reminderID == "done" }!.isCompleted)
        XCTAssertEqual(RemindersPresentation.markers(markers, on: date(2026, 11, 3, 0), calendar: calendar).count, 2)
        XCTAssertTrue(RemindersPresentation.markers(markers, on: date(2026, 11, 4, 0), calendar: calendar).isEmpty)
    }

    func testRemindersNeverBecomeBusyTimeOrTimelineEvents() throws {
        // Markers are a separate type: the Timeline projection and availability inputs accept no reminders.
        let unified = UnifiedTimeline.events(academicItems: [], sources: [], calendarEvents: [])
        XCTAssertTrue(unified.isEmpty)
        let marker = RemindersPresentation.markers(items: [item("a", due: date(2026, 11, 3))], lists: [study],
            in: DateInterval(start: date(2026, 11, 1, 0), end: date(2026, 11, 8, 0)))
        XCTAssertEqual(marker.count, 1)
        // Source-level guard: reminder code must not reference scheduling or busy-time types.
        let source = try String(contentsOf: Self.sourceDirectory.appendingPathComponent("Reminders.swift"), encoding: .utf8)
        for forbidden in ["busyIntervals", "AvailabilitySettings", "ScheduledStudyBlock", "AppleCalendarClient", "UnifiedTimelineEvent("] {
            XCTAssertFalse(source.contains(forbidden), "Reminders.swift must not reference \(forbidden)")
        }
    }

    // MARK: Read-only guarantee

    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AcademicCore")
    }

    func testEventKitRemindersAdapterContainsNoWriteCalls() throws {
        let source = try String(contentsOf: Self.sourceDirectory.appendingPathComponent("EventKitRemindersClient.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for forbidden in [".save(", "saveReminder", ".remove(", "removeReminder", "commit", "saveCalendar", "removeCalendar",
                          "isCompleted =", "completionDate =", ".title =", ".notes =", "EKReminder(eventStore", "requestWriteOnly", ".reset()"] {
            XCTAssertFalse(code.contains(forbidden), "Stage 1 adapter must stay read-only; found \(forbidden)")
        }
        XCTAssertTrue(code.contains("requestFullAccessToReminders"))
    }

    func testClientProtocolOffersNoWriteMembers() throws {
        let source = try String(contentsOf: Self.sourceDirectory.appendingPathComponent("Reminders.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public protocol RemindersClient"))
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.upperBound]
        for forbidden in ["save", "remove", "complete", "delete", "create", "update", "apply"] {
            XCTAssertFalse(body.lowercased().contains(forbidden), "RemindersClient must remain read-only (\(forbidden))")
        }
    }

    func testNoReminderContentIsSentToCloudOrPersisted() throws {
        for name in ["Reminders.swift", "EventKitRemindersClient.swift"] {
            let source = try String(contentsOf: Self.sourceDirectory.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["URLSession", "LocalDatabase", "sqlite3", "FileManager", "UserDefaults", "AssignmentAnalysisProvider", "EmailAnalysisProvider", "print(", "NSLog", "Logger"] {
                XCTAssertFalse(source.contains(forbidden), "\(name) must not reference \(forbidden)")
            }
        }
    }

    func testPackagingDeclaresRemindersUsageDescription() throws {
        let script = Self.sourceDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/package-macos.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("NSRemindersFullAccessUsageDescription"))
        XCTAssertTrue(text.contains("NSCalendarsFullAccessUsageDescription")) // existing Calendar behavior preserved
    }
}
