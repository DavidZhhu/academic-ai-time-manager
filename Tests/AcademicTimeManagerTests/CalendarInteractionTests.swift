import XCTest
@testable import AcademicCore

final class CalendarInteractionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/London")!; return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testClickAndSelectionCreateSnappedProposalsInEitherDirection() {
        let day = date("2026-10-20T00:00:00Z")
        let click = CalendarInteraction.create(on: day, fromMinute: 601, calendar: calendar)
        XCTAssertEqual(calendar.component(.minute, from: click.start), 0)
        XCTAssertEqual(click.end.timeIntervalSince(click.start), 3600)
        let down = CalendarInteraction.create(on: day, fromMinute: 600, toMinute: 650, calendar: calendar)
        let up = CalendarInteraction.create(on: day, fromMinute: 650, toMinute: 600, calendar: calendar)
        XCTAssertEqual(down.start, up.start); XCTAssertEqual(down.end, up.end)
        XCTAssertEqual(down.end.timeIntervalSince(down.start), 2700)
        XCTAssertNil(click.original); XCTAssertTrue(click.key.hasPrefix("interactive:"))
    }
    func testDragAcrossDaysPreservesDurationIdentityAndOriginal() {
        let original = AppleCalendarEvent(id: "owned", calendarID: "managed", marker: "marker", title: "Study",
            start: date("2026-10-20T09:00:00Z"), end: date("2026-10-20T10:30:00Z"), timeZone: "Europe/London")
        let draft = CalendarSessionDraft(key: "slot", event: original)
        let moved = CalendarInteraction.move(draft, to: date("2026-10-22T00:00:00Z"), minute: 751, calendar: calendar)
        XCTAssertEqual(moved.start, date("2026-10-22T11:30:00Z"))
        XCTAssertEqual(moved.end.timeIntervalSince(moved.start), 5400)
        XCTAssertEqual(moved.id, draft.id); XCTAssertEqual(moved.key, draft.key); XCTAssertEqual(moved.original, original)
        XCTAssertEqual(original.start, draft.start)
    }
    func testResizePreservesStartAndIdentityAndRejectsNonpositiveDuration() throws {
        let now = date("2026-10-20T08:00:00Z")
        let draft = CalendarSessionDraft(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        let longer = CalendarInteraction.resize(draft, byMinutes: 23)
        XCTAssertEqual(longer.start, draft.start); XCTAssertEqual(longer.id, draft.id)
        XCTAssertEqual(longer.end, draft.end.addingTimeInterval(1800))
        try longer.validate(now: now)
        XCTAssertThrowsError(try CalendarInteraction.resize(draft, byMinutes: -60).validate(now: now))
        XCTAssertThrowsError(try CalendarInteraction.resize(draft, byMinutes: -90).validate(now: now))
    }
    func testInvalidTitleTimezonePastAndExcessiveRangesAreRejected() {
        let now = date("2026-10-20T08:00:00Z")
        let valid = CalendarSessionDraft(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))
        for change in 0..<6 {
            var draft = valid
            switch change {
            case 0: draft.title = " \n "
            case 1: draft.timeZone = "invalid"
            case 2: draft.start = now
            case 3: draft.end = draft.start.addingTimeInterval(86401)
            case 4: draft.start = now.addingTimeInterval(367 * 86400); draft.end = draft.start.addingTimeInterval(3600)
            default: draft.end = Date(timeIntervalSinceReferenceDate: .infinity)
            }
            XCTAssertThrowsError(try draft.validate(now: now))
        }
    }
    func testDSTRepeatedHourIsIndependentlySelectableAndSpringForwardSkipsGap() {
        let autumn = date("2026-10-25T00:00:00Z")
        let first = CalendarInteraction.snappedDate(on: autumn, minute: 90, calendar: calendar)
        let second = CalendarInteraction.snappedDate(on: autumn, minute: 150, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: first), 1)
        XCTAssertEqual(calendar.component(.hour, from: second), 1)
        XCTAssertEqual(second.timeIntervalSince(first), 3600)
        let spring = CalendarInteraction.snappedDate(on: date("2026-03-29T00:00:00Z"), minute: 90, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: spring), 2)
    }
    func testPersonalAllDayAndUnownedEventsHaveNoEditingCapability() {
        for source in UnifiedTimelineSource.allCases {
            let event = UnifiedTimelineEvent(id: "event", title: "Event", start: Date(), end: Date(), timeZone: "UTC",
                kind: .studyBlock, verification: .verified, source: source, isProtected: true, managedKey: "forged")
            XCTAssertFalse(event.isEditableStudySession)
        }
        let unowned = UnifiedTimelineEvent(id: "event", title: "Study", start: Date(), end: Date(), timeZone: "UTC",
            kind: .studyBlock, verification: .verified, source: .managedCalendar, isProtected: false)
        XCTAssertFalse(unowned.isEditableStudySession)
    }
    func testFixturesRemainTestOnlyAndDefaultDatasetNeverPlansThem() {
        let now = date("2026-10-20T08:00:00Z")
        let fixtures = SampleData.make(now: now)
        let live = AcademicDataset(items: fixtures.items, sources: fixtures.sources, reviews: fixtures.reviews, conflicts: fixtures.conflicts)
        XCTAssertTrue(live.items.isEmpty); XCTAssertTrue(live.assignments.isEmpty)
        XCTAssertTrue(live.reviews.isEmpty); XCTAssertTrue(live.conflicts.isEmpty)
        XCTAssertTrue(live.makePlan(progress: [:], availability: AvailabilitySettings(), now: now).schedule.blocks.isEmpty)
    }
}
