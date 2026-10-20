import Foundation

public enum AcademicCalendarMode: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Window-local presentation state. Filters affect display only, never scheduling or storage.
public struct CalendarPresentationState: Equatable, Sendable {
    public var date: Date
    public var mode: AcademicCalendarMode = .week
    public var visibleSources = Set(UnifiedTimelineSource.allCases)
    public var showsTasks = true
    /// Reminder due-date markers are display-only and independent of event sources.
    public var showsReminderMarkers = true
    public var selectedEventID: String?

    public init(date: Date = Date()) { self.date = date }

    public mutating func move(_ amount: Int, calendar: Calendar = .current) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        date = calendar.date(byAdding: component, value: amount, to: date) ?? date
    }

    public mutating func openDay(_ date: Date) { self.date = date; mode = .day }
}

public struct CalendarEventPlacement: Equatable, Identifiable, Sendable {
    public let event: UnifiedTimelineEvent
    public let startMinute: Double
    public let durationMinutes: Double
    public let column: Int
    public let columnCount: Int
    public var id: String { event.id }
}

public enum CalendarPresentation {
    public static func dayInterval(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    /// Full rows, including adjacent-month dates, are also the Apple Calendar read range.
    public static func days(containing date: Date, mode: AcademicCalendarMode, calendar: Calendar = .current) -> [Date] {
        if mode == .day { return [calendar.startOfDay(for: date)] }
        let anchor = mode == .month ? calendar.dateInterval(of: .month, for: date)!.start : calendar.startOfDay(for: date)
        let leading = (calendar.component(.weekday, from: anchor) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: anchor)!
        let count = mode == .week ? 7 : ((leading + calendar.range(of: .day, in: .month, for: date)!.count + 6) / 7) * 7
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    public static func visibleInterval(date: Date, mode: AcademicCalendarMode, calendar: Calendar = .current) -> DateInterval {
        let dates = days(containing: date, mode: mode, calendar: calendar)
        return DateInterval(start: dates[0], end: dayInterval(dates.last!, calendar: calendar).end)
    }

    public static func events(_ events: [UnifiedTimelineEvent], in interval: DateInterval,
                              sources: Set<UnifiedTimelineSource>) -> [UnifiedTimelineEvent] {
        events.filter { sources.contains($0.source) && $0.start < interval.end && $0.displayEnd > interval.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    /// Elapsed minutes preserve actual durations through 23/25-hour days and repeated hours.
    public static func minuteOffset(_ date: Date, on day: Date, calendar: Calendar = .current) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: day)) / 60
    }

    /// Greedy interval partitioning. Each connected overlap group shares its maximum lane count.
    /// Adjacent events can reuse a lane. Deadlines without duration get a 15-minute display marker;
    /// their authoritative date and end are untouched.
    public static func timedPlacements(_ events: [UnifiedTimelineEvent], on day: Date,
                                       calendar: Calendar = .current) -> [CalendarEventPlacement] {
        let interval = dayInterval(day, calendar: calendar)
        let candidates = self.events(events, in: interval, sources: Set(UnifiedTimelineSource.allCases)).filter { !$0.isAllDay }
        var result: [CalendarEventPlacement] = []
        var group: [(event: UnifiedTimelineEvent, start: Double, end: Double, column: Int)] = []
        var laneEnds: [Double] = []
        var groupEnd = -Double.infinity
        func flush() {
            result += group.map { CalendarEventPlacement(event: $0.event, startMinute: $0.start,
                durationMinutes: $0.end - $0.start, column: $0.column, columnCount: laneEnds.count) }
            group = []; laneEnds = []; groupEnd = -Double.infinity
        }
        for event in candidates {
            let start = max(0, minuteOffset(event.start, on: day, calendar: calendar))
            let displayEnd = event.end > event.start ? event.end : event.start.addingTimeInterval(15 * 60)
            let end = min(interval.duration / 60, minuteOffset(displayEnd, on: day, calendar: calendar))
            if start >= groupEnd { flush() }
            let lane = laneEnds.firstIndex(where: { $0 <= start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            group.append((event, start, end, lane)); groupEnd = max(groupEnd, end)
        }
        flush()
        return result
    }
}
