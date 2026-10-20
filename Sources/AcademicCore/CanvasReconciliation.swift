import Foundation

/// What a Canvas fetch actually covered. Reconciliation only withdraws records inside the covered scope,
/// so a failed, partial or interrupted fetch can never make a record look "removed".
public struct CanvasSyncCoverage: Equatable, Sendable {
    /// Course IDs Canvas listed as active enrolments in this run.
    public let listedCourseIDs: Set<Int>
    /// Courses whose assignment pages were all read successfully.
    public let completeAssignmentCourseIDs: Set<Int>
    /// Courses skipped because Canvas denied or hid their assignments (HTTP 403/404).
    public let incompleteAssignmentCourseIDs: Set<Int>
    /// True only if every calendar-event request succeeded.
    public let eventsComplete: Bool
    /// Events starting inside this interval (shrunk from the requested window to avoid boundary effects)
    /// would have been returned if they still existed.
    public let eventWithdrawalWindow: DateInterval

    public var isComplete: Bool { eventsComplete && incompleteAssignmentCourseIDs.isEmpty }

    public init(listedCourseIDs: Set<Int>, completeAssignmentCourseIDs: Set<Int>, incompleteAssignmentCourseIDs: Set<Int>,
                eventsComplete: Bool, eventWithdrawalWindow: DateInterval) {
        self.listedCourseIDs = listedCourseIDs; self.completeAssignmentCourseIDs = completeAssignmentCourseIDs
        self.incompleteAssignmentCourseIDs = incompleteAssignmentCourseIDs
        self.eventsComplete = eventsComplete; self.eventWithdrawalWindow = eventWithdrawalWindow
    }
}

/// Bookkeeping stored beside, never inside, imported source records and items.
public struct CanvasRecordStatus: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case source, item }
    public enum State: String, Codable, Sendable { case active, withdrawn }
    public let recordID: String
    public let kind: Kind
    public var state: State
    public var reason: String
    public var changedAt: Date
}

public struct CanvasReconciliationSummary: Equatable, Sendable {
    public var withdrawnSources = 0
    public var withdrawnItems = 0
    public var detachedItems = 0
    public var reinstated = 0
    /// Set when reconciliation was deliberately not run (no coverage, or a suspicious empty course list).
    public var skippedReason: String?
    public var changedAnything: Bool { withdrawnSources + withdrawnItems + detachedItems + reinstated > 0 }
}

struct CanvasReconciliationPlan: Equatable {
    var withdrawSources: [String: String] = [:]
    var withdrawItems: [String: String] = [:]
    /// Items that also carry approved non-Canvas provenance keep existing, minus their Canvas source IDs.
    var detachItems: [AcademicItem] = []
}

enum CanvasReconciler {
    private enum Identity { case course(Int), assignment(course: Int), event }

    private static func identity(of externalID: String) -> Identity? {
        let parts = externalID.split(separator: "-").map(String.init)
        if parts.count == 2, parts[0] == "course", let id = Int(parts[1]) { return .course(id) }
        if parts.count == 4, parts[0] == "course", parts[2] == "assignment", let id = Int(parts[1]), Int(parts[3]) != nil { return .assignment(course: id) }
        if parts.count == 3, parts[0] == "calendar", parts[1] == "event", Int(parts[2]) != nil { return .event }
        return nil
    }

    /// `activeSources` and `activeItems` are the stored, not-yet-withdrawn records after this run's upserts.
    static func plan(activeSources: [SourceRecord], activeItems: [AcademicItem], result: CanvasImportResult,
                     coverage: CanvasSyncCoverage) -> (plan: CanvasReconciliationPlan?, skippedReason: String?) {
        let canvas = activeSources.filter { $0.provider == "Canvas" }
        let hadCourses = canvas.contains { if case .course = identity(of: $0.externalID) { return true } else { return false } }
        if coverage.listedCourseIDs.isEmpty && hadCourses {
            return (nil, "Canvas returned no active courses, so nothing was withdrawn. Check enrolment or try again.")
        }
        let seenSources = Set(result.sourceRecords.map(\.id)), seenItems = Set(result.academicItems.map(\.id))
        let itemsByID = Dictionary(activeItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let providers = Dictionary(activeSources.map { ($0.id, $0.provider) }, uniquingKeysWith: { first, _ in first })
        var plan = CanvasReconciliationPlan()
        var itemWithdrawals: [String: String] = [:]

        for source in canvas {
            switch identity(of: source.externalID) {
            case .course(let course):
                if !coverage.listedCourseIDs.contains(course), !seenSources.contains(source.id) {
                    plan.withdrawSources[source.id] = "Course is no longer an active Canvas enrolment"
                }
            case .assignment(let course):
                if !coverage.listedCourseIDs.contains(course) {
                    plan.withdrawSources[source.id] = "Course is no longer an active Canvas enrolment"
                    itemWithdrawals[source.id] = "Course is no longer an active Canvas enrolment"
                } else if coverage.completeAssignmentCourseIDs.contains(course), !seenSources.contains(source.id) {
                    plan.withdrawSources[source.id] = "Assignment is no longer returned by Canvas"
                    itemWithdrawals[source.id] = "Assignment is no longer returned by Canvas"
                } else if seenSources.contains(source.id), !seenItems.contains(source.id), itemsByID[source.id] != nil {
                    itemWithdrawals[source.id] = "Canvas no longer provides a due date"
                }
            case .event:
                guard coverage.eventsComplete, !seenSources.contains(source.id),
                      let item = itemsByID[source.id], coverage.eventWithdrawalWindow.contains(item.startsAt) else { continue }
                plan.withdrawSources[source.id] = "Event is no longer returned by Canvas"
                itemWithdrawals[source.id] = "Event is no longer returned by Canvas"
            case nil:
                continue
            }
        }
        for (id, reason) in itemWithdrawals {
            guard var item = itemsByID[id] else { continue }
            let kept = item.sourceRecordIDs.filter { providers[$0].map { $0 != "Canvas" } ?? false }
            if kept.isEmpty { plan.withdrawItems[id] = reason }
            else { item.sourceRecordIDs = kept; plan.detachItems.append(item) }
        }
        plan.detachItems.sort { $0.id < $1.id }
        return (plan, nil)
    }
}
