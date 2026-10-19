import Foundation

public struct ConflictCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let value: String
    public let sourceRecordID: String
    public let observedAt: Date

    public init(id: String, value: String, sourceRecordID: String, observedAt: Date) {
        self.id = id; self.value = value; self.sourceRecordID = sourceRecordID; self.observedAt = observedAt
    }
}

public enum ConflictState: String, Codable, Sendable { case unresolved, resolved }

public struct AcademicConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let field: String
    public let candidates: [ConflictCandidate]
    public var state: ConflictState
    public var resolution: String?
    public var resolvedBy: String?

    public init(id: String, field: String, candidates: [ConflictCandidate], state: ConflictState = .unresolved, resolution: String? = nil, resolvedBy: String? = nil) {
        self.id = id; self.field = field; self.candidates = candidates; self.state = state
        self.resolution = resolution; self.resolvedBy = resolvedBy
    }
}

public enum AcademicConflictDetector {
    /// Returns all distinct source values as unresolved; it never chooses an authoritative value.
    public static func detect(id: String, field: String, candidates: [ConflictCandidate]) -> AcademicConflict? {
        let distinctValues = Set(candidates.map(\.value))
        guard distinctValues.count > 1 else { return nil }
        return AcademicConflict(id: id, field: field, candidates: candidates)
    }
}

public enum ApprovalDecision: String, Codable, Sendable { case pending, approved, rejected }

public struct ChangeApproval: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let actionType: String
    public let proposedDiff: String
    public let riskLevel: String
    public var decision: ApprovalDecision
    public var decidedAt: Date?

    public init(id: String, actionType: String, proposedDiff: String, riskLevel: String, decision: ApprovalDecision = .pending, decidedAt: Date? = nil) {
        self.id = id; self.actionType = actionType; self.proposedDiff = proposedDiff
        self.riskLevel = riskLevel; self.decision = decision; self.decidedAt = decidedAt
    }
}

public struct AuditEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let actor: String
    public let action: String
    public let targetID: String
    public let beforeReference: String?
    public let afterReference: String?
    public let timestamp: Date

    public init(id: String, actor: String, action: String, targetID: String, beforeReference: String? = nil, afterReference: String? = nil, timestamp: Date) {
        self.id = id; self.actor = actor; self.action = action; self.targetID = targetID
        self.beforeReference = beforeReference; self.afterReference = afterReference; self.timestamp = timestamp
    }
}

public enum ConflictValueFormatter {
    public static func display(_ value: String, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return "\(formatter.string(from: date)) (\(timeZone.identifier))"
    }
}
