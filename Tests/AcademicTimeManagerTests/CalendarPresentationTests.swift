import XCTest
@testable import AcademicCore

final class CalendarPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func event(_ id: String, _ start: String, _ end: String? = nil,
                       source: UnifiedTimelineSource = .canvas, allDay: Bool = false) -> UnifiedTimelineEvent {
        UnifiedTimelineEvent(id: id, title: "Original \(id)", start: date(start), end: date(end ?? start),
            timeZone: "Europe/London", kind: end == nil ? .deadline : .classSession,
            verification: .verified, source: source, isProtected: true, isAllDay: allDay)
    }
    private let allSources = Set(UnifiedTimelineSource.allCases)

    func testWeekHasSevenLocaleOrderedDatesAndExclusiveEnd() {
        let day = date("2026-10-21T11:00:00Z")
        let days = CalendarPresentation.days(containing: day, mode: .week, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(calendar.component(.day, from: days[0]), 19)
        let interval = CalendarPresentation.visibleInterval(date: day, mode: .week, calendar: calendar)
        XCTAssertEqual(interval.start, days[0])
        XCTAssertEqual(interval.end, date("2026-10-26T00:00:00Z"))
        var sunday = calendar; sunday.firstWeekday = 1
        XCTAssertEqual(sunday.component(.weekday, from: CalendarPresentation.days(containing: day, mode: .week, calendar: sunday)[0]), 1)
    }

    func testMonthIncludesFullRowsAdjacentMonthsAndLeapDay() {
        let day = date("2028-02-15T12:00:00Z")
        let days = CalendarPresentation.days(containing: day, mode: .month, calendar: calendar)
        XCTAssertEqual(days.count % 7, 0)
        XCTAssertEqual(days[0], date("2028-01-31T00:00:00Z"))
        XCTAssertTrue(days.contains(date("2028-02-29T00:00:00Z")))
        let range = CalendarPresentation.visibleInterval(date: day, mode: .month, calendar: calendar)
        XCTAssertEqual(range.end, date("2028-03-06T00:00:00Z"))
        let sixRows = CalendarPresentation.days(containing: date("2026-03-15T12:00:00Z"), mode: .month, calendar: calendar)
        XCTAssertEqual(sixRows.count, 42)
    }

    func testMonthNavigationAcrossYearKeepsFiltersPanelAndSelection() {
        var state = CalendarPresentationState(date: date("2026-12-31T12:00:00Z"))
        state.mode = .month; state.visibleSources = [.canvas, .outlook]
        state.showsTasks = false; state.selectedEventID = "selected"
        state.move(1, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: state.date), 2027)
        XCTAssertEqual(calendar.component(.month, from: state.date), 1)
        state.openDay(date("2027-01-05T00:00:00Z"))
        XCTAssertEqual(state.mode, .day)
        XCTAssertEqual(state.visibleSources, [.canvas, .outlook])
        XCTAssertFalse(state.showsTasks)
        XCTAssertEqual(state.selectedEventID, "selected")
        state.move(-1, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: state.date), 4)
    }

    func testFiltersEverySourceAndEmptySelectionWithoutMutatingInput() {
        let events = UnifiedTimelineSource.allCases.map { event($0.rawValue, "2026-10-19T10:00:00Z", "2026-10-19T11:00:00Z", source: $0) }
        let original = events
        let interval = CalendarPresentation.dayInterval(date("2026-10-19T12:00:00Z"), calendar: calendar)
        for source in UnifiedTimelineSource.allCases {
            XCTAssertEqual(CalendarPresentation.events(events, in: interval, sources: [source]).map(\.source), [source])
        }
        XCTAssertTrue(CalendarPresentation.events(events, in: interval, sources: []).isEmpty)
        XCTAssertEqual(CalendarPresentation.events(events, in: interval, sources: allSources).count, events.count)
        XCTAssertEqual(events, original)
    }

    func testMidnightBoundariesAndDeadlineInstant() {
        let interval = CalendarPresentation.dayInterval(date("2026-10-20T12:00:00Z"), calendar: calendar)
        let events = [event("ending", "2026-10-19T21:00:00Z", "2026-10-19T23:00:00Z"),
                      event("starting", "2026-10-20T23:00:00Z", "2026-10-21T01:00:00Z"),
                      event("deadline", "2026-10-19T23:00:00Z")]
        XCTAssertEqual(CalendarPresentation.events(events, in: interval, sources: allSources).map(\.id), ["deadline"])
    }

    func testActualStartAndDurationDeterminePlacement() {
        let event = event("lecture", "2026-10-19T08:30:00Z", "2026-10-19T09:45:00Z")
        let placements = CalendarPresentation.timedPlacements([event], on: event.start, calendar: calendar)
        XCTAssertEqual(placements[0].startMinute, 9 * 60 + 30)
        XCTAssertEqual(placements[0].durationMinutes, 75)
        XCTAssertEqual(placements[0].column, 0)
        XCTAssertEqual(placements[0].columnCount, 1)
        XCTAssertEqual(placements[0].event.title, "Original lecture")
        XCTAssertTrue(placements[0].event.isProtected)
    }

    func testOverlapsUseLanesAndIndependentGroupsRegainFullWidth() {
        let events = [event("a", "2026-10-19T09:00:00Z", "2026-10-19T11:00:00Z"),
                      event("b", "2026-10-19T09:30:00Z", "2026-10-19T10:30:00Z"),
                      event("c", "2026-10-19T10:00:00Z", "2026-10-19T12:00:00Z"),
                      event("d", "2026-10-19T12:00:00Z", "2026-10-19T13:00:00Z")]
        let placements = CalendarPresentation.timedPlacements(events, on: events[0].start, calendar: calendar)
        XCTAssertEqual(placements.map(\.column), [0, 1, 2, 0])
        XCTAssertEqual(placements.map(\.columnCount), [3, 3, 3, 1])
        XCTAssertEqual(placements, CalendarPresentation.timedPlacements(events.reversed(), on: events[0].start, calendar: calendar))
    }

    func testChainOverlapsReuseLanesAndTouchingEventsDoNotOverlap() {
        let events = [event("a", "2026-10-19T09:00:00Z", "2026-10-19T10:00:00Z"),
                      event("b", "2026-10-19T09:30:00Z", "2026-10-19T10:30:00Z"),
                      event("c", "2026-10-19T10:00:00Z", "2026-10-19T11:00:00Z")]
        let placements = CalendarPresentation.timedPlacements(events, on: events[0].start, calendar: calendar)
        XCTAssertEqual(placements.map(\.column), [0, 1, 0])
        XCTAssertEqual(placements.map(\.columnCount), [2, 2, 2])
        let adjacent = CalendarPresentation.timedPlacements([events[0], events[2]], on: events[0].start, calendar: calendar)
        XCTAssertEqual(adjacent.map(\.columnCount), [1, 1])
    }

    func testAllDayEventsStayOutOfHourlyGridAndSpanDays() {
        let event = event("all-day", "2026-10-18T23:00:00Z", "2026-10-21T23:00:00Z", source: .appleCalendar, allDay: true)
        for value in ["2026-10-19T12:00:00Z", "2026-10-20T12:00:00Z", "2026-10-21T12:00:00Z"] {
            let day = date(value)
            XCTAssertEqual(CalendarPresentation.events([event], in: CalendarPresentation.dayInterval(day, calendar: calendar), sources: allSources), [event])
            XCTAssertTrue(CalendarPresentation.timedPlacements([event], on: day, calendar: calendar).isEmpty)
        }
        XCTAssertTrue(CalendarPresentation.events([event], in: CalendarPresentation.dayInterval(event.end, calendar: calendar), sources: allSources).isEmpty)
    }

    func testOvernightEventsClipAtDayBoundariesWithoutChangingSource() {
        let event = event("overnight", "2026-10-19T22:30:00Z", "2026-10-20T01:00:00Z")
        let first = CalendarPresentation.timedPlacements([event], on: event.start, calendar: calendar)[0]
        let second = CalendarPresentation.timedPlacements([event], on: event.end, calendar: calendar)[0]
        XCTAssertEqual(first.startMinute, 23 * 60 + 30)
        XCTAssertEqual(first.durationMinutes, 30)
        XCTAssertEqual(second.startMinute, 0)
        XCTAssertEqual(second.durationMinutes, 120)
        XCTAssertEqual(first.event, event); XCTAssertEqual(second.event, event)
    }

    func testZeroDurationDeadlineGetsDisplayMarkerOnlyAndClipsAtMidnight() {
        let event = event("deadline", "2026-10-19T22:55:00Z")
        let placement = CalendarPresentation.timedPlacements([event], on: event.start, calendar: calendar)[0]
        XCTAssertEqual(placement.durationMinutes, 5)
        XCTAssertEqual(placement.event.start, placement.event.end)
        XCTAssertEqual(placement.event.kind, .deadline)
    }

    func testSpringDSTPreservesDurationAndCalendarDayNavigation() {
        let day = date("2026-03-29T00:00:00Z")
        XCTAssertEqual(CalendarPresentation.dayInterval(day, calendar: calendar).duration / 3600, 23)
        let event = event("spring", "2026-03-29T00:30:00Z", "2026-03-29T02:30:00Z")
        let placement = CalendarPresentation.timedPlacements([event], on: day, calendar: calendar)[0]
        XCTAssertEqual(placement.startMinute, 30)
        XCTAssertEqual(placement.durationMinutes, 120)
        var state = CalendarPresentationState(date: day); state.mode = .day
        state.move(1, calendar: calendar)
        XCTAssertEqual(state.date, date("2026-03-29T23:00:00Z"))
    }

    func testAutumnDSTRepeatedHourKeepsDistinctInstantsAndLanes() {
        let day = date("2026-10-25T00:00:00Z")
        XCTAssertEqual(CalendarPresentation.dayInterval(day, calendar: calendar).duration / 3600, 25)
        let events = [event("first-0130", "2026-10-25T00:30:00Z", "2026-10-25T00:45:00Z"),
                      event("second-0130", "2026-10-25T01:30:00Z", "2026-10-25T01:45:00Z")]
        let placements = CalendarPresentation.timedPlacements(events, on: day, calendar: calendar)
        XCTAssertEqual(placements.map(\.startMinute), [90, 150])
        XCTAssertEqual(placements.map(\.durationMinutes), [15, 15])
        XCTAssertEqual(placements.map(\.columnCount), [1, 1])
    }

    func testFilteredProjectionNeverMixesLiveAndDemoOrMutatesSchedulingConstraints() {
        let now = date("2026-10-19T08:00:00Z")
        let sources = [SourceRecord(id: "live", provider: "Canvas", externalID: "1", retrievedAt: now),
                       SourceRecord(id: "demo", provider: "Canvas (sample)", externalID: "2", retrievedAt: now)]
        let items = sources.map { source in
            AcademicItem(id: source.id, title: source.id, startsAt: now, endsAt: now.addingTimeInterval(3600),
                timeZoneIdentifier: "Europe/London", kind: .classSession, verification: .verified,
                sourceRecordIDs: [source.id], isProtected: true)
        }
        for (mode, expected) in [(StudyDataMode.live, "academic:live"), (.demo, "academic:demo")] {
            let dataset = AcademicDataset(mode: mode, items: items, sources: sources)
            let projection = UnifiedTimeline.events(academicItems: dataset.items, sources: dataset.sources, calendarEvents: [])
            let interval = CalendarPresentation.dayInterval(now, calendar: calendar)
            XCTAssertTrue(CalendarPresentation.events(projection, in: interval, sources: []).isEmpty)
            XCTAssertEqual(CalendarPresentation.events(projection, in: interval, sources: allSources).map(\.id), [expected])
            XCTAssertEqual(dataset.items.count, 1)
            XCTAssertTrue(dataset.items[0].isProtected)
        }
    }
}
