import Foundation
import AcademicCore

public enum SampleData {
    public static func make(now: Date = Date(), timeZone: TimeZone = .current) -> (sources: [SourceRecord], items: [AcademicItem], reviews: [ReviewItem], conflicts: [AcademicConflict]) {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: now)
        func date(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: offset, to: day)!)!
        }
        let source = SourceRecord(id: "source-canvas-demo", provider: "Canvas (sample)", externalID: "assignment-42", retrievedAt: now, sourceURI: "https://canvas.example.invalid/courses/1/assignments/42")
        let outlookSource = SourceRecord(id: "source-outlook-demo", provider: "Outlook (sample)", externalID: "message-7", retrievedAt: now, sourceURI: "https://outlook.example.invalid/message/7")
        let classItem = AcademicItem(id: "class-algorithms", title: "Algorithms lecture", startsAt: date(0, 10), endsAt: date(0, 11), timeZoneIdentifier: timeZone.identifier, kind: .classSession, verification: .verified, sourceRecordIDs: [source.id], isProtected: true)
        let deadline = AcademicItem(id: "deadline-problem-sheet", title: "Problem sheet 3 due", startsAt: date(4, 16), endsAt: date(4, 16, 30), timeZoneIdentifier: timeZone.identifier, kind: .deadline, verification: .verified, sourceRecordIDs: [source.id], isProtected: true)
        let study = AcademicItem(id: "study-demo", title: "Review graph algorithms", startsAt: date(0, 14), endsAt: date(0, 15), timeZoneIdentifier: timeZone.identifier, kind: .studyBlock, verification: .inferred, sourceRecordIDs: [source.id])
        let review = ReviewItem(id: "review-tutorial", title: "Possible tutorial: Numerical Methods", evidence: "Sample email fixture: ‘We may meet Thursday at 2pm; room to follow.’", confidence: 0.62, state: .disputed, sourceRecordID: outlookSource.id)
        let formatter = ISO8601DateFormatter()
        let conflict = AcademicConflictDetector.detect(id: "conflict-problem-sheet-deadline", field: "Problem sheet 3 due time", candidates: [
            ConflictCandidate(id: "canvas-deadline", value: formatter.string(from: date(4, 16)), sourceRecordID: source.id, observedAt: now),
            ConflictCandidate(id: "outlook-deadline", value: formatter.string(from: date(4, 17)), sourceRecordID: outlookSource.id, observedAt: now)
        ])!
        return ([source, outlookSource], [classItem, study, deadline], [review], [conflict])
    }
}
