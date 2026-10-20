import Foundation

public struct CanvasSyncReport: Equatable, Sendable {
    public let courseCount: Int
    public let sourceRecordCount: Int
    public let academicItemCount: Int
    public let completedAt: Date
    /// Courses whose assignments Canvas refused (403/404) or calendar events that could not be read.
    public let skippedCourseCount: Int
    public let eventsComplete: Bool
}

public struct CanvasSyncBatch: Sendable {
    public let result: CanvasImportResult
    public let completedAt: Date
    /// Only a complete fetch may be recorded as the last successful sync.
    public var isComplete: Bool { result.coverage?.isComplete ?? true }
    public var report: CanvasSyncReport {
        CanvasSyncReport(
            courseCount: result.sourceRecords.filter { $0.externalID.hasPrefix("course-") && !$0.externalID.contains("-assignment-") }.count,
            sourceRecordCount: result.sourceRecords.count,
            academicItemCount: result.academicItems.count,
            completedAt: completedAt,
            skippedCourseCount: result.coverage?.incompleteAssignmentCourseIDs.count ?? 0,
            eventsComplete: result.coverage?.eventsComplete ?? true
        )
    }
}

/// Retrieves the existing token from Keychain only when the user requests a sync.
/// It writes imported Canvas data and the success timestamp to SQLite in one transaction.
public struct CanvasSyncService: Sendable {
    private let tokenStore: any CanvasTokenStoring
    private let transport: any CanvasTransport
    private let baseURL: URL

    public init(tokenStore: any CanvasTokenStoring = KeychainCanvasTokenStore(), transport: any CanvasTransport = URLSessionCanvasTransport(), baseURL: URL = CanvasAPIConnectionValidator.oxfordBaseURL) {
        self.tokenStore = tokenStore; self.transport = transport; self.baseURL = baseURL
    }

    public func fetch(at date: Date = Date()) async throws -> CanvasSyncBatch {
        guard let token = try tokenStore.readToken(), !token.isEmpty else { throw CanvasConnectionError.noSavedToken }
        let importer = try CanvasImporter(baseURL: baseURL, accessToken: token, transport: transport)
        let result = try await importer.fetchAssignments(retrievedAt: date)
        return CanvasSyncBatch(result: result, completedAt: Date())
    }
}
