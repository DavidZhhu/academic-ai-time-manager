import Foundation

public enum VerificationState: String, Codable, CaseIterable, Sendable {
    case verified, inferred, disputed
}

public enum AcademicItemKind: String, Codable, Sendable {
    case classSession, tutorial, deadline, studyBlock
}

public struct SourceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let externalID: String
    public let retrievedAt: Date
    public let sourceURI: String?
    public let payloadReference: String?
    public let displayTitle: String?
    public let assignmentDetails: ImportedAssignmentDetails?

    public init(id: String, provider: String, externalID: String, retrievedAt: Date, sourceURI: String? = nil, payloadReference: String? = nil, displayTitle: String? = nil, assignmentDetails: ImportedAssignmentDetails? = nil) {
        self.id = id; self.provider = provider; self.externalID = externalID; self.retrievedAt = retrievedAt
        self.sourceURI = sourceURI; self.payloadReference = payloadReference; self.displayTitle = displayTitle
        self.assignmentDetails = assignmentDetails
    }
}

public struct AcademicItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    public var timeZoneIdentifier: String
    public var kind: AcademicItemKind
    public var verification: VerificationState
    public var sourceRecordIDs: [String]
    public var isProtected: Bool

    public init(id: String, title: String, startsAt: Date, endsAt: Date, timeZoneIdentifier: String, kind: AcademicItemKind, verification: VerificationState, sourceRecordIDs: [String], isProtected: Bool = false) {
        self.id = id; self.title = title; self.startsAt = startsAt; self.endsAt = endsAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.kind = kind; self.verification = verification; self.sourceRecordIDs = sourceRecordIDs; self.isProtected = isProtected
    }
}

public enum ReviewDecision: String, Codable, Sendable {
    case pending, accepted, rejected
}

public struct ReviewItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var evidence: String
    public var confidence: Double
    public var state: VerificationState
    public var decision: ReviewDecision
    public var sourceRecordID: String

    public init(id: String, title: String, evidence: String, confidence: Double, state: VerificationState, decision: ReviewDecision = .pending, sourceRecordID: String) {
        self.id = id; self.title = title; self.evidence = evidence; self.confidence = confidence; self.state = state; self.decision = decision; self.sourceRecordID = sourceRecordID
    }
}

public struct AvailabilitySettings: Codable, Equatable, Sendable {
    public var studyStartHour: Int
    public var studyEndHour: Int
    public var protectedRestStartHour: Int
    public var protectedRestEndHour: Int
    public var timeZoneIdentifier: String

    public init(studyStartHour: Int = 9, studyEndHour: Int = 18, protectedRestStartHour: Int = 22, protectedRestEndHour: Int = 8, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.studyStartHour = studyStartHour; self.studyEndHour = studyEndHour
        self.protectedRestStartHour = protectedRestStartHour; self.protectedRestEndHour = protectedRestEndHour
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
