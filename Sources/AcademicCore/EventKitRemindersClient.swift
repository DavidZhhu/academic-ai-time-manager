import EventKit
import Foundation

private final class EventKitRemindersObservation: AppleCalendarChangeObservation {
    private var token: NSObjectProtocol?
    init(store: EKEventStore, handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
    }
    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
    deinit { cancel() }
}

/// Read-only EventKit adapter. It reads lists and reminders and observes change notifications.
/// It never calls `save`, `remove`, `commit` or assigns to a reminder (a test enforces this).
/// Constructing it does not instantiate EventKit or request permission.
@MainActor public final class EventKitRemindersClient: RemindersClient {
    private var storedStore: EKEventStore?
    private var store: EKEventStore {
        if let storedStore { return storedStore }
        let value = EKEventStore(); storedStore = value; return value
    }
    public init() {}

    public var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    public func requestAccess() async throws {
        do { guard try await store.requestFullAccessToReminders() else { throw RemindersError.permission } }
        catch { throw RemindersError.permission }
    }

    private func requireAccess() throws { guard access == .fullAccess else { throw RemindersError.permission } }

    public func lists() throws -> [ReminderListInfo] {
        try requireAccess()
        return store.calendars(for: .reminder).map { calendar in
            ReminderListInfo(id: calendar.calendarIdentifier, title: calendar.title,
                             sourceID: calendar.source?.sourceIdentifier ?? "", sourceTitle: calendar.source?.title ?? "")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func reminders(in listIDs: [String]) async throws -> [ReminderItem] {
        try requireAccess()
        let calendars = store.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        let fetched: [ReminderItem]? = await withCheckedContinuation { continuation in
            // Convert to Sendable values inside the callback; EKReminder never leaves it.
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.map(Self.item))
            }
        }
        guard let fetched else { throw RemindersError.unavailable }
        try requireAccess()
        return fetched
    }

    public func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleCalendarChangeObservation {
        EventKitRemindersObservation(store: store, handler: handler)
    }

    /// EKReminder exposes no public parent/subtask, section or attachment property, so
    /// `parentID` stays nil. For a recurring reminder EventKit yields the single series entry with
    /// its current due date, not expanded occurrences.
    nonisolated private static func item(_ reminder: EKReminder) -> ReminderItem {
        let rule = reminder.recurrenceRules?.first
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            externalID: reminder.calendarItemExternalIdentifier,
            listID: reminder.calendar.calendarIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            due: reminder.dueDateComponents.flatMap { ReminderDue(components: $0) },
            priority: ReminderPriority(eventKitValue: reminder.priority),
            isCompleted: reminder.isCompleted,
            completedAt: reminder.completionDate,
            url: reminder.url,
            parentID: nil,
            isRecurring: reminder.hasRecurrenceRules,
            recurrenceSummary: rule.map(summary),
            lastModified: reminder.lastModifiedDate)
    }

    nonisolated private static func summary(_ rule: EKRecurrenceRule) -> String {
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "period"
        }
        return rule.interval <= 1 ? "Repeats every \(unit)" : "Repeats every \(rule.interval) \(unit)s"
    }
}
