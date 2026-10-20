import Foundation

/// An in-memory proposal only. A stable creation ID survives editor/preview retries; existing
/// sessions carry the exact owned snapshot the user started editing. Never contains personal events.
public struct CalendarSessionDraft: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let key: String
    public let original: AppleCalendarEvent?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZone: String

    public init(id: UUID = UUID(), start: Date, end: Date, title: String = "Study session", timeZone: String = TimeZone.current.identifier) {
        self.id = id; key = "interactive:\(id.uuidString)"; original = nil
        self.title = title; self.start = start; self.end = end; self.timeZone = timeZone
    }
    public init(key: String, event: AppleCalendarEvent) {
        id = UUID(); self.key = key; original = event
        title = event.title; start = event.start; end = event.end; timeZone = event.timeZone
    }
    public func validate(now: Date) throws {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              start > now, start.timeIntervalSince(now) < 366 * 86400,
              end > start, end.timeIntervalSince(start) <= 86400,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeZone(identifier: timeZone) != nil else { throw AppleCalendarError.invalidPlan }
    }
    public var previewEvent: UnifiedTimelineEvent {
        UnifiedTimelineEvent(id: "proposal:\(id)", title: "Proposed: \(title)", start: start, end: end,
            timeZone: timeZone, kind: .studyBlock, verification: .inferred, source: .managedCalendar, isProtected: false)
    }
}

/// Pointer and keyboard editors share absolute dates. Grid coordinates are elapsed minutes from
/// local midnight, so a repeated DST hour remains independently selectable. Gestures snap to 15m.
public enum CalendarInteraction {
    public static func snappedDate(on day: Date, minute: Double, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval((minute / 15).rounded() * 15 * 60)
    }
    public static func move(_ draft: CalendarSessionDraft, to day: Date, minute: Double,
                            calendar: Calendar = .current) -> CalendarSessionDraft {
        var result = draft
        result.start = snappedDate(on: day, minute: minute, calendar: calendar)
        result.end = result.start.addingTimeInterval(draft.end.timeIntervalSince(draft.start))
        return result
    }
    public static func resize(_ draft: CalendarSessionDraft, byMinutes minutes: Double) -> CalendarSessionDraft {
        var result = draft
        result.end = draft.end.addingTimeInterval((minutes / 15).rounded() * 15 * 60)
        return result
    }
    public static func create(on day: Date, fromMinute: Double, toMinute: Double? = nil,
                              calendar: Calendar = .current) -> CalendarSessionDraft {
        let start = snappedDate(on: day, minute: min(fromMinute, toMinute ?? fromMinute), calendar: calendar)
        let end = toMinute.map { snappedDate(on: day, minute: max(fromMinute, $0), calendar: calendar) }
        return CalendarSessionDraft(start: start, end: end.map { max($0, start.addingTimeInterval(900)) } ?? start.addingTimeInterval(3600),
                                    timeZone: calendar.timeZone.identifier)
    }
}
