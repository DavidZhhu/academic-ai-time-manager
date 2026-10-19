import Foundation

public enum StudyDataMode: String, CaseIterable, Sendable {
    case live, demo

    public var label: String { self == .live ? "Canvas data" : "Demo Mode" }
}

public extension SourceRecord {
    /// Recognizes persisted provenance from earlier builds without rewriting imported records.
    /// Unknown providers remain unclassified until their adapter defines an origin.
    var studyDataMode: StudyDataMode? {
        if ["source-canvas-demo", "source-outlook-demo"].contains(id) { return .demo }
        switch provider {
        case "Canvas (sample)", "Outlook (sample)": return .demo
        case "Canvas": return .live
        default: return nil
        }
    }
}

/// The app's shared data boundary for display and planning. Selecting a mode never mutates storage.
public struct AcademicDataset: Sendable {
    public let mode: StudyDataMode
    public let sources: [SourceRecord]
    public let items: [AcademicItem]
    public let reviews: [ReviewItem]
    public let conflicts: [AcademicConflict]

    public init(mode: StudyDataMode = .live, items: [AcademicItem], sources: [SourceRecord],
                reviews: [ReviewItem] = [], conflicts: [AcademicConflict] = []) {
        self.mode = mode
        self.sources = sources.filter { $0.studyDataMode == mode }
        let sourceIDs = Set(self.sources.map(\.id))
        // Every source must belong to the selected mode. Missing or mixed provenance cannot
        // accidentally turn a sample assignment or commitment into real academic work.
        func includes(_ ids: [String]) -> Bool { !ids.isEmpty && ids.allSatisfy(sourceIDs.contains) }
        self.items = items.filter { includes($0.sourceRecordIDs) }
        self.reviews = reviews.filter { includes([$0.sourceRecordID]) }
        self.conflicts = conflicts.filter { includes($0.candidates.map(\.sourceRecordID)) }
    }

    public var assignments: [PlanningAssignment] {
        AssignmentPlanning.assignments(items: items, sources: sources)
    }

    public func makePlan(progress: [String: AssignmentProgress], availability: AvailabilitySettings,
                         estimates: [String: Int] = [:], priorities: [String: Int] = [:], now: Date) -> AssignmentStudyPlan {
        AssignmentPlanning.makePlan(assignments: assignments, progress: progress, items: items,
            availability: availability, estimates: estimates, priorities: priorities, now: now)
    }
}
