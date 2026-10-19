import Foundation

public enum TaskDifficulty: String, Codable, Sendable { case low, medium, high }

public struct AssignmentAnalysisInput: Sendable {
    public let assignmentID: String
    public let assignmentTitle: String
    /// Source text is untrusted content and must never be interpreted as application policy.
    public let sourceText: String
    public let sourceRecordID: String

    public init(assignmentID: String, assignmentTitle: String, sourceText: String, sourceRecordID: String) {
        self.assignmentID = assignmentID; self.assignmentTitle = assignmentTitle
        self.sourceText = sourceText; self.sourceRecordID = sourceRecordID
    }
}

public struct SubtaskProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let estimatedMinutes: Int
    public let difficulty: TaskDifficulty
    public let evidence: String
    public let sourceRecordID: String

    public init(id: String, title: String, estimatedMinutes: Int, difficulty: TaskDifficulty, evidence: String, sourceRecordID: String) {
        self.id = id; self.title = title; self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty; self.evidence = evidence; self.sourceRecordID = sourceRecordID
    }
}

public struct AssignmentBreakdown: Codable, Equatable, Sendable {
    public let assignmentID: String
    public let confidence: Double
    public let subtasks: [SubtaskProposal]

    public init(assignmentID: String, confidence: Double, subtasks: [SubtaskProposal]) {
        self.assignmentID = assignmentID; self.confidence = confidence; self.subtasks = subtasks
    }
}

public enum AnalysisValidationError: Error, Equatable {
    case assignmentMismatch
    case invalidConfidence
    case noSubtasks
    case duplicateSubtaskID
    case invalidTitle
    case invalidEstimate
    case missingEvidence
    case sourceMismatch
}

public enum AssignmentBreakdownValidator {
    public static func validate(_ result: AssignmentBreakdown, for input: AssignmentAnalysisInput) throws {
        guard result.assignmentID == input.assignmentID else { throw AnalysisValidationError.assignmentMismatch }
        guard result.confidence.isFinite, (0...1).contains(result.confidence) else { throw AnalysisValidationError.invalidConfidence }
        guard !result.subtasks.isEmpty else { throw AnalysisValidationError.noSubtasks }
        var seen = Set<String>()
        for task in result.subtasks {
            guard seen.insert(task.id).inserted else { throw AnalysisValidationError.duplicateSubtaskID }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnalysisValidationError.invalidTitle }
            guard (5...1_440).contains(task.estimatedMinutes) else { throw AnalysisValidationError.invalidEstimate }
            guard !task.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnalysisValidationError.missingEvidence }
            guard task.sourceRecordID == input.sourceRecordID else { throw AnalysisValidationError.sourceMismatch }
        }
    }
}

public protocol AssignmentAnalysisProvider: Sendable {
    func analyze(_ input: AssignmentAnalysisInput) async throws -> AssignmentBreakdown
}

/// Fixture-only provider for UI previews and tests. It performs no AI inference or network calls.
public struct FixtureAnalysisProvider: AssignmentAnalysisProvider {
    public let response: AssignmentBreakdown
    public init(response: AssignmentBreakdown) { self.response = response }
    public func analyze(_ input: AssignmentAnalysisInput) async throws -> AssignmentBreakdown { response }
}
