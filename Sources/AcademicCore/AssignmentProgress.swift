import Foundation

public enum AssignmentStatus: String, Codable, CaseIterable, Sendable {
    case notStarted, inProgress, completed

    public var label: String {
        switch self {
        case .notStarted: "Not Started"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        }
    }
}

/// User-owned state, stored separately from replaceable Canvas source facts.
public struct AssignmentProgress: Codable, Equatable, Sendable {
    public let assignmentID: String
    public let status: AssignmentStatus
    public let updatedAt: Date

    public init(assignmentID: String, status: AssignmentStatus, updatedAt: Date = Date()) {
        self.assignmentID = assignmentID; self.status = status; self.updatedAt = updatedAt
    }
}

/// Only the current user's submission state and timestamp are retained; no grades or submission content.
public struct CanvasSubmissionEvidence: Codable, Equatable, Sendable {
    public let submittedAt: Date?
    public let workflowState: String?
    enum CodingKeys: String, CodingKey { case submittedAt = "submitted_at", workflowState = "workflow_state" }

    public var suggestsCompletion: Bool {
        submittedAt != nil && ["submitted", "pending_review", "graded"].contains(workflowState ?? "")
    }
}

public struct ImportedAssignmentDetails: Codable, Equatable, Sendable {
    public let dueAt: Date?
    public let submission: CanvasSubmissionEvidence?

    public init(dueAt: Date?, submission: CanvasSubmissionEvidence? = nil) {
        self.dueAt = dueAt; self.submission = submission
    }
}

public enum AssignmentPlanningGroup: String, CaseIterable, Sendable {
    case active, overdue, undated, completed
    public var label: String {
        switch self {
        case .active: "Upcoming assignments"
        case .overdue: "Overdue"
        case .undated: "No deadline"
        case .completed: "Completed"
        }
    }
}

public struct PlanningAssignment: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let dueAt: Date?
    public let sourceRecordIDs: [String]
    public let submission: CanvasSubmissionEvidence?
    public let retrievedAt: Date?

    public func group(status: AssignmentStatus, now: Date) -> AssignmentPlanningGroup {
        if status == .completed { return .completed }
        guard let dueAt else { return .undated }
        return dueAt <= now ? .overdue : .active
    }
}

public struct AssignmentStudyPlan: Sendable {
    public let schedule: ScheduleResult
    public let expiresAt: Date?

    public func isCurrent(at now: Date) -> Bool { expiresAt.map { now < $0 } ?? true }
}

public enum AssignmentPlanning {
    /// Older cached deadlines work immediately. New import metadata also represents undated assignments.
    public static func assignments(items: [AcademicItem], sources: [SourceRecord]) -> [PlanningAssignment] {
        var byID: [String: PlanningAssignment] = [:]
        for item in items where item.kind == .deadline {
            byID[item.id] = PlanningAssignment(id: item.id, title: item.title, dueAt: item.startsAt,
                sourceRecordIDs: item.sourceRecordIDs, submission: nil, retrievedAt: nil)
        }
        for source in sources {
            guard let details = source.assignmentDetails else { continue }
            byID[source.id] = PlanningAssignment(id: source.id, title: source.displayTitle ?? byID[source.id]?.title ?? "Canvas assignment",
                dueAt: details.dueAt, sourceRecordIDs: [source.id], submission: details.submission, retrievedAt: source.retrievedAt)
        }
        return byID.values.sorted {
            if $0.dueAt != $1.dueAt { return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            return $0.id < $1.id
        }
    }

    /// This is the app's scheduling entry point. Eligibility is checked before generating any work stages.
    public static func makePlan(assignments: [PlanningAssignment], progress: [String: AssignmentProgress],
                                items: [AcademicItem], availability: AvailabilitySettings,
                                estimates: [String: Int] = [:], priorities: [String: Int] = [:], now: Date) -> AssignmentStudyPlan {
        let eligible = assignments.filter { $0.group(status: progress[$0.id]?.status ?? .notStarted, now: now) == .active }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: availability.timeZoneIdentifier) ?? .current
        let latest = eligible.compactMap(\.dueAt).max() ?? now
        let days = min(365, max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: latest)).day ?? 0) + 1))
        let windows = eligible.isEmpty ? [] : AvailabilityWindowBuilder.windows(from: now, dayCount: days, settings: availability)
        let fixed = items.filter { $0.isProtected && $0.kind != .deadline && $0.endsAt > now }
            .map { DateInterval(start: $0.startsAt, end: $0.endsAt) }
        let tasks = eligible.flatMap { assignment -> [StudyTask] in
            guard let due = assignment.dueAt else { return [] }
            let estimate = AssignmentEffortEstimate(id: assignment.id, estimatedMinutes: estimates[assignment.id] ?? 180,
                priority: priorities[assignment.id] ?? 3, sourceRecordIDs: assignment.sourceRecordIDs)
            return StudyTaskBreakdown.propose(for: assignment.title, estimate: estimate, dueAt: due)
        }
        return AssignmentStudyPlan(schedule: StudyScheduler.makePlan(tasks: tasks, availableWindows: windows, fixedEvents: fixed),
                                   expiresAt: eligible.compactMap(\.dueAt).min())
    }
}
