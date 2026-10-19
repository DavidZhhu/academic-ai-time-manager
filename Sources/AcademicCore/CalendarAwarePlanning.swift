import Foundation

/// Calendar busy time joins the existing hard constraints without changing source provenance or persistence.
@MainActor public enum CalendarAwarePlanning {
    public static func makePlan(dataset: AcademicDataset, progress: [String: AssignmentProgress],
                                availability: AvailabilitySettings, estimates: [String: Int] = [:], priorities: [String: Int] = [:],
                                now: Date, calendar: AppleCalendarService?) throws -> AssignmentStudyPlan {
        let latest = dataset.assignments.compactMap(\.dueAt).max() ?? now
        var busy: [DateInterval] = []
        if dataset.mode == .live, let calendar, latest > now {
            busy = try calendar.busyIntervals(in: DateInterval(start: now, end: min(latest, now.addingTimeInterval(365 * 86400))))
        }
        let commitments = busy.enumerated().map { index, interval in
            AcademicItem(id: "apple-busy-\(index)", title: "Calendar commitment", startsAt: interval.start,
                endsAt: interval.end, timeZoneIdentifier: availability.timeZoneIdentifier,
                kind: .classSession, verification: .verified, sourceRecordIDs: [], isProtected: true)
        }
        return AssignmentPlanning.makePlan(assignments: dataset.assignments, progress: progress,
            items: dataset.items + commitments, availability: availability, estimates: estimates, priorities: priorities, now: now)
    }
}
