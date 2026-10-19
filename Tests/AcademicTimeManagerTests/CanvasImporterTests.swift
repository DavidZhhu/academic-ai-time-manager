import Foundation
import XCTest
@testable import AcademicCore

private struct FixtureResponse: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
}

private actor FixtureCanvasTransport: CanvasTransport {
    private var fixtures: [FixtureResponse]
    private var received: [URLRequest] = []

    init(_ fixtures: [FixtureResponse]) { self.fixtures = fixtures }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        received.append(request)
        guard !fixtures.isEmpty else { throw CanvasImportError.invalidResponse }
        let fixture = fixtures.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        return (fixture.data, response)
    }

    func requestCount() -> Int { received.count }
    func allRequests() -> [URLRequest] { received }
}

private actor FlakyCanvasTransport: CanvasTransport {
    private var attempts = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        if attempts == 1 { throw URLError(.networkConnectionLost) }
        return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
    func requestCount() -> Int { attempts }
}

final class CanvasImporterTests: XCTestCase {
    func testCurrentUserSubmissionEvidenceSuggestsCompletionWithoutChangingLocalStatus() async throws {
        let assignmentsJSON = #"""
        [
          {"id":0,"name":"Submitted","due_at":"2027-03-01T17:00:00Z","submission":{"workflow_state":"submitted","submitted_at":"2026-10-19T09:00:00+01:00","body":"must-not-be-retained","grade":"private-grade"}},
          {"id":1,"name":"Graded without submission","due_at":null,"submission":{"workflow_state":"graded","submitted_at":null}},
          {"id":2,"name":"Someone submitted","due_at":null,"has_submitted_submissions":true},
          {"id":3,"name":"Pending review","due_at":"2027-03-01T17:00:00Z","submission":{"workflow_state":"pending_review","submitted_at":"2026-10-19T08:00:00.123Z"}},
          {"id":4,"name":"Malformed evidence","due_at":null,"submission":{"workflow_state":"submitted","submitted_at":"not-a-date"}},
          {"id":5,"name":"Unsubmitted","due_at":null,"submission":{"workflow_state":"unsubmitted","submitted_at":"2026-10-19T08:00:00Z"}},
          {"id":6,"name":"Graded submission","due_at":null,"submission":{"workflow_state":"graded","submitted_at":"2026-10-19T08:00:00Z"}},
          {"id":7,"name":"Unknown status","due_at":null,"submission":{"workflow_state":"unknown","submitted_at":"2026-10-19T08:00:00Z"}}
        ]
        """#
        let transport = FixtureCanvasTransport([
            .init(data: Data(#"[{"id":1,"name":"Course","time_zone":"Europe/London"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data(assignmentsJSON.utf8), status: 200, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: [:])
        ])
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token", transport: transport, sleep: { _ in })
        let result = try await importer.fetchAssignments()
        let db = try LocalDatabase()
        let completedID = "canvas-course-1-assignment-0"
        try db.save(AssignmentProgress(assignmentID: completedID, status: .completed))
        try db.importCanvas(result)
        try db.importCanvas(result)
        XCTAssertEqual(try db.assignmentProgress()[completedID]?.status, .completed)
        XCTAssertEqual(try db.assignmentProgress().count, 1, "Submission evidence must never create local status decisions")
        let assignments = AssignmentPlanning.assignments(items: try db.items(), sources: try db.sourceRecords())
        XCTAssertEqual(assignments.count, 8)
        XCTAssertEqual(Set(assignments.filter { $0.submission?.suggestsCompletion == true }.map(\.id)),
                       Set([0, 3, 6].map { "canvas-course-1-assignment-\($0)" }))
        let requests = await transport.allRequests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "include[]", value: "submission")) == true)
        let persisted = String(decoding: try JSONEncoder().encode(db.sourceRecords()), as: UTF8.self)
        XCTAssertFalse(persisted.contains("must-not-be-retained"))
        XCTAssertFalse(persisted.contains("private-grade"))
    }

    func testFetchesCoursesAndPaginatedAssignmentsAsVerifiedRecords() async throws {
        let transport = FixtureCanvasTransport([
            .init(data: Data(#"[{"id":1,"name":"Algorithms"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data(#"[{"id":10,"name":"Problem Set","due_at":"2027-03-01T17:00:00Z","html_url":"https://canvas.example/courses/1/assignments/10"}]"#.utf8), status: 200, headers: ["Link": "<https://canvas.example/api/v1/courses/1/assignments?page=2>; rel=\"next\""]),
            .init(data: Data(#"[{"id":11,"name":"Reading","due_at":null}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: [:])
        ])
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token-not-a-credential", transport: transport, sleep: { _ in })
        let imported = try await importer.fetchAssignments(retrievedAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(imported.sourceRecords.count, 3)
        XCTAssertEqual(imported.academicItems.count, 1)
        XCTAssertEqual(imported.academicItems[0].title, "Algorithms: Problem Set")
        XCTAssertEqual(imported.academicItems[0].verification, .verified)
        XCTAssertEqual(imported.academicItems[0].timeZoneIdentifier, "UTC")
        let db = try LocalDatabase()
        try db.importCanvas(imported)
        try db.importCanvas(imported)
        XCTAssertEqual(try db.sourceRecordCount(), 3)
        XCTAssertEqual(try db.items().count, 1)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 4)
        let requests = await transport.allRequests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token-not-a-credential" })
    }

    func testImportsPaginatedCalendarEventsAndCourseTimeZone() async throws {
        let transport = FixtureCanvasTransport([
            .init(data: Data(#"[{"id":9,"name":"Mathematics","time_zone":"Europe/London"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: [:]),
            .init(data: Data(#"[{"id":77,"title":"Lecture","start_at":"2026-10-25T09:00:00+00:00","end_at":"2026-10-25T10:00:00+00:00","context_name":"Mathematics","context_code":"course_9","html_url":"https://canvas.example/calendar?event_id=77"}]"#.utf8), status: 200, headers: ["Link": "<https://canvas.example/api/v1/calendar_events?page=2>; rel=\"next\""]),
            .init(data: Data(#"[{"id":77,"title":"Lecture duplicate","start_at":"2026-10-25T09:00:00Z","end_at":"2026-10-25T10:00:00Z","context_name":"Mathematics","context_code":"course_9"}]"#.utf8), status: 200, headers: [:])
        ])
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token", transport: transport, sleep: { _ in })
        let fixedNow = ISO8601DateFormatter().date(from: "2026-10-19T10:00:00Z")!
        let result = try await importer.fetchAssignments(retrievedAt: fixedNow)
        XCTAssertEqual(result.sourceRecords.count, 2)
        XCTAssertEqual(result.academicItems.count, 1, "A repeated Canvas event ID must be imported only once")
        XCTAssertEqual(result.sourceRecords.first(where: { $0.externalID == "course-9" })?.displayTitle, "Mathematics")
        XCTAssertEqual(result.academicItems[0].title, "Mathematics: Lecture")
        XCTAssertEqual(result.academicItems[0].timeZoneIdentifier, "Europe/London")
        XCTAssertEqual(result.academicItems[0].startsAt, ISO8601DateFormatter().date(from: "2026-10-25T09:00:00Z"))
        let requests = await transport.allRequests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        let eventURL = try XCTUnwrap(requests[2].url)
        XCTAssertEqual(URLComponents(url: eventURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "context_codes[]" })?.value, "course_9")
        XCTAssertTrue(URLComponents(url: eventURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "start_date" && $0.value == "2026-09-19" }) == true)
    }

    func testSyncServicePersistsDataAndLastSuccessfulTimeWithoutStoringToken() async throws {
        let transport = FixtureCanvasTransport([
            .init(data: Data(#"[{"id":1,"name":"Logic"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data(#"[{"id":2,"name":"Essay","due_at":"2027-01-10T12:00:00+00:00"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: [:])
        ])
        let db = try LocalDatabase()
        let sync = CanvasSyncService(tokenStore: FixtureTokenStore("only-a-test-token"), transport: transport, baseURL: URL(string: "https://canvas.example")!)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = try await sync.fetch(at: fixedNow)
        let report = batch.report
        try db.importCanvas(batch.result, successfulAt: fixedNow)
        XCTAssertEqual(report.courseCount, 1)
        XCTAssertEqual(report.academicItemCount, 1)
        XCTAssertEqual(try db.items().count, 1)
        XCTAssertEqual(try db.lastSuccessfulCanvasSync(), fixedNow)
        XCTAssertFalse(try db.sourceRecords().contains(where: { $0.displayTitle == "only-a-test-token" }))
    }

    func testFailedSyncDoesNotAdvanceLastSuccessfulTimeAndDoesNotExposeToken() async throws {
        let transport = FixtureCanvasTransport([.init(data: Data("{}".utf8), status: 401, headers: [:])])
        let db = try LocalDatabase()
        let sync = CanvasSyncService(tokenStore: FixtureTokenStore("never-log-this-fixture"), transport: transport, baseURL: URL(string: "https://canvas.example")!)
        do {
            let batch = try await sync.fetch(at: Date(timeIntervalSince1970: 7))
            try db.importCanvas(batch.result, successfulAt: batch.completedAt)
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? CanvasImportError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("never-log-this-fixture"))
        }
        XCTAssertNil(try db.lastSuccessfulCanvasSync())
        XCTAssertTrue(try db.sourceRecords().isEmpty)
    }

    func testRetriesRateLimitResponseWithInjectedNoOpDelay() async throws {
        let transport = FixtureCanvasTransport([
            .init(data: Data("{}".utf8), status: 429, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: [:])
        ])
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token", transport: transport, sleep: { _ in })
        let result = try await importer.fetchAssignments()
        XCTAssertTrue(result.sourceRecords.isEmpty)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testRetriesTransientNetworkFailureWithInjectedNoOpDelay() async throws {
        let transport = FlakyCanvasTransport()
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token", transport: transport, sleep: { _ in })
        let result = try await importer.fetchAssignments()
        XCTAssertTrue(result.sourceRecords.isEmpty)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
    }

    func testRejectsNonHTTPSBaseURL() {
        XCTAssertThrowsError(try CanvasImporter(baseURL: URL(string: "http://canvas.example")!, accessToken: "fixture-token", transport: FixtureCanvasTransport([]))) { error in
            XCTAssertEqual(error as? CanvasImportError, .invalidBaseURL)
        }
    }

    func testRejectsPaginationLinkToDifferentOriginBeforeSendingToken() async throws {
        let transport = FixtureCanvasTransport([
            .init(data: Data(#"[{"id":1,"name":"Algorithms"}]"#.utf8), status: 200, headers: [:]),
            .init(data: Data("[]".utf8), status: 200, headers: ["Link": "<https://attacker.example/steal>; rel=\"next\""])
        ])
        let importer = try CanvasImporter(baseURL: URL(string: "https://canvas.example")!, accessToken: "fixture-token", transport: transport, sleep: { _ in })
        do {
            _ = try await importer.fetchAssignments()
            XCTFail("Expected unsafe pagination URL to be rejected")
        } catch {
            XCTAssertEqual(error as? CanvasImportError, .unsafePaginationURL)
            let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
        }
    }
}

private struct FixtureTokenStore: CanvasTokenStoring {
    let token: String?
    init(_ token: String?) { self.token = token }
    func save(token: String) throws { XCTFail("Sync tests must not save credentials") }
    func readToken() throws -> String? { token }
    func hasToken() throws -> Bool { token != nil }
    func deleteToken() throws { XCTFail("Sync tests must not delete credentials") }
}
