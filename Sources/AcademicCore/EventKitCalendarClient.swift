import EventKit
import Foundation

private final class EventKitChangeObservation: AppleCalendarChangeObservation {
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

/// Constructing this adapter does not instantiate EventKit or request permissions.
@MainActor public final class EventKitCalendarClient: AppleCalendarClient {
    public static let calendarTitle = "Academic AI Time Manager"
    private var storedEventStore: EKEventStore?
    private var store: EKEventStore {
        if let storedEventStore { return storedEventStore }
        let value = EKEventStore(); storedEventStore = value; return value
    }
    public init() {}
    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }
    public func requestAccess() async throws {
        do { guard try await store.requestFullAccessToEvents() else { throw AppleCalendarError.permission } }
        catch { throw AppleCalendarError.permission }
    }
    private func requireAccess() throws { guard access == .fullAccess else { throw AppleCalendarError.permission } }
    public func sources() throws -> [AppleCalendarSource] {
        try requireAccess()
        return store.sources.filter { [.local, .calDAV, .exchange].contains($0.sourceType) }
            .map { AppleCalendarSource(id: $0.sourceIdentifier, title: $0.title) }
    }
    public func createCalendar(sourceID: String) throws -> String {
        try requireAccess()
        // Name alone never establishes ownership. Existing same-name calendars require manual resolution.
        guard !store.calendars(for: .event).contains(where: { $0.title == Self.calendarTitle }),
              let source = store.sources.first(where: { $0.sourceIdentifier == sourceID && [.local, .calDAV, .exchange].contains($0.sourceType) }) else {
            throw AppleCalendarError.unavailable
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitle; calendar.source = source
        do { try store.saveCalendar(calendar, commit: true); return calendar.calendarIdentifier }
        catch { store.reset(); throw AppleCalendarError.unavailable }
    }
    public func validateCalendar(id: String) throws {
        try requireAccess()
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications,
              !calendar.isSubscribed, calendar.type != .birthday else { throw AppleCalendarError.unavailable }
    }
    public func events(in interval: DateInterval) throws -> [AppleCalendarEvent] {
        try requireAccess()
        guard interval.duration > 0, interval.duration <= 370 * 86400 else { throw AppleCalendarError.invalidPlan }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let result = store.events(matching: predicate).map(snapshot)
        try requireAccess(); return result
    }
    public func event(id: String) throws -> AppleCalendarEvent? {
        try requireAccess(); return store.event(withIdentifier: id).map(snapshot)
    }
    public func observeChanges(_ handler: @escaping @MainActor () -> Void) -> any AppleCalendarChangeObservation {
        // The EventKit store is created only after the user has explicitly refreshed a granted connection.
        EventKitChangeObservation(store: store, handler: handler)
    }
    public func apply(before: AppleCalendarEvent?, after: AppleCalendarEvent?) throws -> AppleCalendarEvent? {
        try requireAccess()
        guard let desired = after ?? before else { throw AppleCalendarError.invalidPlan }
        try validateCalendar(id: desired.calendarID)
        let event: EKEvent
        if let before {
            guard after == nil || (after?.calendarID == before.calendarID && after?.marker == before.marker) else { throw AppleCalendarError.ownership }
            guard let existing = store.event(withIdentifier: before.id), snapshot(existing) == before,
                  before.isSafeToModify, before.marker != nil else { throw AppleCalendarError.ownership }
            event = existing
        } else { event = EKEvent(eventStore: store) }
        do {
            if let after {
                guard after.calendarID == desired.calendarID, let marker = after.marker, UUID(uuidString: marker) != nil else { throw AppleCalendarError.ownership }
                event.calendar = store.calendar(withIdentifier: after.calendarID)
                event.title = after.title; event.startDate = after.start; event.endDate = after.end
                event.timeZone = TimeZone(identifier: after.timeZone); event.isAllDay = false
                event.notes = Self.note(marker); event.url = Self.url(marker)
                event.availability = .busy
                try store.save(event, span: .thisEvent, commit: true)
                return snapshot(event)
            }
            try store.remove(event, span: .thisEvent, commit: true); return nil
        } catch { store.reset(); throw AppleCalendarError.unavailable }
    }
    private static func note(_ marker: String) -> String { "Academic AI Time Manager managed study session. Ownership: \(marker)" }
    private static func url(_ marker: String) -> URL? { URL(string: "academic-time-manager://study/\(marker)") }
    private func snapshot(_ event: EKEvent) -> AppleCalendarEvent {
        let marker: String? = {
            guard let url = event.url, url.scheme == "academic-time-manager", url.host == "study",
                  UUID(uuidString: url.lastPathComponent) != nil else { return nil }
            return url.lastPathComponent
        }()
        let safe = marker.map { event.notes == Self.note($0) && event.url == Self.url($0) } == true
            && !event.isAllDay && !event.hasRecurrenceRules && !event.isDetached
            && !event.hasAttendees && !event.hasAlarms && event.location == nil
            && event.status != .canceled && event.structuredLocation == nil
        return AppleCalendarEvent(id: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarID: event.calendar.calendarIdentifier, marker: marker, title: event.title ?? "",
            start: event.startDate, end: event.endDate, timeZone: event.timeZone?.identifier ?? "",
            isBusy: event.availability != .free && event.status != .canceled, isSafeToModify: safe,
            isAllDay: event.isAllDay)
    }
}
