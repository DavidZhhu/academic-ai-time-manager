import XCTest
@testable import AcademicCore

actor MicrosoftMockTransport: CanvasTransport {
    struct Reply: Sendable {
        var status = 200
        var data: Data
        var headers: [String: String] = [:]
        init(_ value: Any, status: Int = 200, headers: [String: String] = [:]) {
            self.status = status; self.data = try! JSONSerialization.data(withJSONObject: value); self.headers = headers
        }
        init(data: Data) { self.data = data }
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}
final class MemoryMicrosoftStore: MicrosoftCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: MicrosoftCredentials] = [:]
    func read(accountID: String) throws -> MicrosoftCredentials? { lock.withLock { values[accountID] } }
    func save(_ credentials: MicrosoftCredentials, accountID: String) throws { lock.withLock { values[accountID] = credentials } }
    func remove(accountID: String) throws { _ = lock.withLock { values.removeValue(forKey: accountID) } }
}

final class OutlookIntegrationTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!
    let clientID = "11111111-1111-1111-1111-111111111111"
    let delta = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=mock-checkpoint"
    var account: OutlookAccount { OutlookAccount(profileID: "mock-user", clientID: clientID, label: "Oxford fixture", address: "fixture@example.invalid", now: now) }
    var profile: [String: Any] { ["id": "mock-user", "displayName": "Fixture"] }
    func message(_ id: String = "m1", body: String = "Tutorial on 2026-10-21 14:00", subject: String = "Tutorial", attachments: Bool = false) -> [String: Any] {
        ["id": id, "subject": subject, "body": ["contentType": "text", "content": body],
         "from": ["emailAddress": ["address": "tutor@example.invalid"]], "receivedDateTime": "2026-10-18T10:00:00Z",
         "lastModifiedDateTime": "2026-10-18T10:00:00Z", "hasAttachments": attachments, "webLink": "https://outlook.office.com/mail/inbox/id/mock"]
    }
    func state() -> OutlookState { var state = OutlookState(); state.accounts = [account]; return state }
    func graph(_ transport: MicrosoftMockTransport) -> MicrosoftGraphClient {
        MicrosoftGraphClient(transport: transport, token: { _ in "mock-only-access" }, sleep: { _ in })
    }

    func testPKCEChallengeRandomStateAndStrictCallbackValidation() throws {
        XCTAssertEqual(MicrosoftAuthorization.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let auth = try MicrosoftAuthorization(clientID: clientID), second = try MicrosoftAuthorization(clientID: clientID)
        XCTAssertNotEqual(auth.state, second.state); XCTAssertNotEqual(auth.verifier, second.verifier)
        XCTAssertGreaterThanOrEqual(auth.verifier.count, 43)
        let fields = URLComponents(url: auth.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(fields.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
        XCTAssertFalse(fields.contains { $0.name == "client_secret" })
        XCTAssertEqual(try auth.code(from: URL(string: MicrosoftAuthorization.redirectURI + "?code=fake&state=" + auth.state)!), "fake")
        for url in [MicrosoftAuthorization.redirectURI + "?code=fake&state=wrong", "evil://auth?code=fake&state=" + auth.state,
                    MicrosoftAuthorization.redirectURI + "?code=fake&state=" + auth.state + "&state=" + auth.state] {
            XCTAssertThrowsError(try auth.code(from: URL(string: url)!))
        }
        XCTAssertThrowsError(try MicrosoftAuthorization(clientID: "not-an-app-id"))
    }

    func testOAuthExchangeAndPerAccountRefreshRotation() async throws {
        let auth = try MicrosoftAuthorization(clientID: clientID)
        let transport = MicrosoftMockTransport([.init(["access_token": "mock-new", "refresh_token": "mock-refresh", "expires_in": 3600, "token_type": "Bearer", "scope": "User.Read Mail.Read"]),
            .init(["access_token": "mock-refreshed", "refresh_token": "mock-rotated", "expires_in": 3600, "token_type": "Bearer"])])
        let credential = try await MicrosoftOAuthClient(transport: transport).exchange(auth,
            callback: URL(string: MicrosoftAuthorization.redirectURI + "?code=mock-code&state=" + auth.state)!, now: now)
        let store = MemoryMicrosoftStore(); try store.save(credential, accountID: account.id); try store.save(credential, accountID: "other-account")
        let token = try await MicrosoftSession(account: account, store: store, transport: transport).accessToken(forceRefresh: true)
        XCTAssertEqual(token, "mock-refreshed")
        XCTAssertEqual(try store.read(accountID: account.id)?.refreshToken, "mock-rotated")
        XCTAssertEqual(try store.read(accountID: "other-account"), credential)
        try store.remove(accountID: account.id)
        XCTAssertNil(try store.read(accountID: account.id)); XCTAssertNotNil(try store.read(accountID: "other-account"))
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.host == "login.microsoftonline.com" })
        let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("code_verifier=")); XCTAssertFalse(body.contains("client_secret"))
    }

    func testRevokedRefreshFailsWithSanitizedReconnectError() async throws {
        let transport = MicrosoftMockTransport([.init(["error": "invalid_grant", "error_description": "mock-sensitive-text"], status: 400)])
        let store = MemoryMicrosoftStore()
        try store.save(MicrosoftCredentials(accessToken: "old", refreshToken: "mock-refresh", expiresAt: .distantPast), accountID: account.id)
        do { _ = try await MicrosoftSession(account: account, store: store, transport: transport).accessToken(); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .reconnect); XCTAssertFalse(error.localizedDescription.contains("mock-sensitive")) }
    }

    func testPaginationInitialWindowPersistenceAndIncrementalNoDuplicates() async throws {
        let next = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=mock"
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.nextLink": next]),
            .init(["value": [message("m2", body: "Deadline 2026-10-22 17:00", subject: "Deadline")], "@odata.deltaLink": delta]),
            .init(profile), .init(["value": [message()], "@odata.deltaLink": delta])])
        let db = try LocalDatabase(); try db.save(state())
        let first = try await graph(transport).synchronize(account: account, previous: state(), now: now)
        XCTAssertEqual(first.proposals.count, 2); try db.importOutlook(first)
        let saved = try db.outlookState()
        let nextBatch = try await graph(transport).synchronize(account: saved.accounts[0], previous: saved, now: now.addingTimeInterval(60))
        XCTAssertTrue(nextBatch.proposals.isEmpty); try db.importOutlook(nextBatch)
        XCTAssertEqual(try db.outlookState().proposals.count, 2); XCTAssertEqual(try db.outlookState().accounts[0].deltaLink, delta)
        XCTAssertEqual(try db.sourceRecordCount(), 2)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertTrue(requests[1].url!.absoluteString.contains("receivedDateTime")); XCTAssertTrue(requests[1].url!.absoluteString.contains("2026-09-19"))
        XCTAssertEqual(requests[4].url!.absoluteString, delta)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(try db.outlookState()), as: UTF8.self).contains("mock-only-access"))
    }

    func testUnsafeNextLinksLeaveCheckpointUnchanged() async throws {
        for next in ["https://evil.example.invalid/steal", "https://graph.microsoft.com/v1.0/users/other/messages/delta"] {
            let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.nextLink": next])])
            let db = try LocalDatabase(); try db.save(state())
            do { _ = try await graph(transport).synchronize(account: account, previous: state(), now: now); XCTFail() }
            catch { XCTAssertEqual(error as? OutlookError, .unsafeLink) }
            XCTAssertNil(try db.outlookState().accounts[0].lastSuccessfulSync); XCTAssertTrue(try db.outlookState().proposals.isEmpty)
            let count = await transport.requests.count; XCTAssertEqual(count, 2)
        }
    }

    func testRetriesThrottlingAndUnauthorizedThenValidResponse() async throws {
        let transport = MicrosoftMockTransport([.init([:], status: 401), .init([:], status: 429, headers: ["Retry-After": "1"]), .init(profile)])
        let p = try await graph(transport).profile(); XCTAssertEqual(p.id, account.profileID)
        let count = await transport.requests.count; XCTAssertEqual(count, 3)
    }

    func testExpiredDeltaRestartsThirtyDayWindow() async throws {
        var previous = state(); previous.accounts[0].deltaLink = delta
        let transport = MicrosoftMockTransport([.init(profile), .init([:], status: 410), .init(["value": [message()], "@odata.deltaLink": delta])])
        let result = try await graph(transport).synchronize(account: previous.accounts[0], previous: previous, now: now)
        XCTAssertEqual(result.account.initialSince, now.addingTimeInterval(-30*86400)); XCTAssertTrue(result.notices.contains { $0.contains("checkpoint expired") })
    }

    func testMultipleAccountsSameMessageIDsAndDuplicateApproval() async throws {
        let second = OutlookAccount(profileID: "personal", clientID: clientID, label: "Personal", address: "personal@example.invalid", now: now)
        var saved = state(); saved.accounts.append(second)
        let db = try LocalDatabase(); try db.save(saved)
        for account in saved.accounts {
            let transport = MicrosoftMockTransport([.init(["id": account.profileID]), .init(["value": [message()], "@odata.deltaLink": delta])])
            try db.importOutlook(try await graph(transport).synchronize(account: account, previous: try db.outlookState(), now: now))
        }
        let result = try db.outlookState()
        XCTAssertEqual(result.messages.count, 2); XCTAssertEqual(result.proposals.count, 2)
        XCTAssertEqual(Set(result.proposals.map(\.accountID)).count, 2); XCTAssertEqual(Set(result.proposals.map(\.sourceID)).count, 2)
        XCTAssertEqual(result.proposals.filter { $0.duplicateOf != nil }.count, 1)
        try db.decideOutlook(ids: Set(result.proposals.map(\.id)), decision: .accepted)
        XCTAssertEqual(try db.items().count, 1); XCTAssertEqual(try db.items()[0].sourceRecordIDs.count, 2)
    }

    func testBatchReviewRollbackAndApprovalGate() async throws {
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message(), message("ambiguous", body: "Tutorial next Thursday", subject: "Tutorial next week")], "@odata.deltaLink": delta])])
        let db = try LocalDatabase(); try db.save(state())
        try db.importOutlook(try await graph(transport).synchronize(account: account, previous: state(), now: now))
        XCTAssertTrue(try db.items().isEmpty)
        let proposals = try db.outlookState().proposals
        XCTAssertThrowsError(try db.decideOutlook(ids: Set(proposals.map(\.id)), decision: .accepted))
        XCTAssertTrue(try db.items().isEmpty); XCTAssertTrue(try db.outlookState().proposals.allSatisfy { $0.decision == .pending })
        let dated = try XCTUnwrap(proposals.first { $0.date != nil })
        try db.decideOutlook(ids: [dated.id], decision: .accepted)
        try db.decideOutlook(ids: Set(proposals.filter { $0.date == nil }.map(\.id)), decision: .rejected)
        XCTAssertEqual(try db.items().count, 1); XCTAssertEqual(try db.auditEntries().count, 2); XCTAssertTrue(try db.items()[0].isProtected)
    }

    func testRemovedMessagesPreserveApprovedCommitments() async throws {
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.deltaLink": delta]),
            .init(profile), .init(["value": [["id": "m1", "@removed": ["reason": "deleted"]]], "@odata.deltaLink": delta])])
        let db = try LocalDatabase(); try db.save(state())
        try db.importOutlook(try await graph(transport).synchronize(account: account, previous: state(), now: now))
        try db.decideOutlook(ids: Set(try db.outlookState().proposals.map(\.id)), decision: .accepted)
        let saved = try db.outlookState()
        try db.importOutlook(try await graph(transport).synchronize(account: saved.accounts[0], previous: saved, now: now))
        XCTAssertEqual(try db.items().count, 1); XCTAssertTrue(try db.outlookState().proposals[0].withdrawn)
    }

    func testAccountIdentityMismatchStopsBeforeInboxRead() async throws {
        let transport = MicrosoftMockTransport([.init(["id": "different-user"])])
        do { _ = try await graph(transport).synchronize(account: account, previous: state(), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .reconnect) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }

    func testPollingIsOptInAndBoundedAndDisconnectedAccountsNeverPoll() {
        var settings = OutlookSettings(); var account = self.account
        XCTAssertFalse(account.pollingDue(settings: settings, now: now))
        settings.pollingEnabled = true; settings.pollingMinutes = 0
        XCTAssertEqual(settings.pollInterval, 300); XCTAssertTrue(account.pollingDue(settings: settings, now: now))
        account.lastSuccessfulSync = now; XCTAssertFalse(account.pollingDue(settings: settings, now: now))
        account.connected = false; XCTAssertFalse(account.pollingDue(settings: settings, now: now.addingTimeInterval(10000)))
    }
}

extension OutlookIntegrationTests {
    func testRelevantDOCXAttachmentPaginatedMetadataAndPrivacyOptOut() async throws {
        let docx = mockDOCX([("[Content_Types].xml", "<Types/>"), ("word/document.xml", "<w:document xmlns:w='urn:test'><w:p><w:r><w:t>Deadline 2026-10-22 17:00</w:t></w:r></w:p></w:document>")], compressed: true)
        let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let path = "https://graph.microsoft.com/v1.0/me/messages/m1/attachments"
        let metadata: [String: Any] = ["id": "file1", "name": "work.docx", "contentType": mime, "size": docx.count, "isInline": false, "@odata.type": "#microsoft.graph.fileAttachment"]
        let unsupported: [String: Any] = ["id": "file2", "name": "bad.exe", "contentType": "application/octet-stream", "size": 100, "@odata.type": "#microsoft.graph.fileAttachment"]
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message(attachments: true)], "@odata.deltaLink": delta]),
            .init(["value": [metadata], "@odata.nextLink": path + "?$skiptoken=mock"]), .init(data: docx), .init(["value": [unsupported]])])
        let result = try await graph(transport).synchronize(account: account, previous: state(), now: now)
        XCTAssertTrue(result.proposals.contains { $0.attachmentName == "work.docx" && $0.kind == .deadline })
        XCTAssertFalse(result.notices.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        var settings = state(); settings.settings.analyzeAttachments = false
        let optOut = MicrosoftMockTransport([.init(profile), .init(["value": [message(attachments: true)], "@odata.deltaLink": delta])])
        let noAttachments = try await graph(optOut).synchronize(account: account, previous: settings, now: now)
        XCTAssertTrue(noAttachments.proposals.allSatisfy { $0.attachmentName == nil })
        let count = await optOut.requests.count; XCTAssertEqual(count, 2)
    }

    func testTransientNetworkExhaustionAndRepeated401AreBounded() async throws {
        let offline = MicrosoftMockTransport([])
        do { _ = try await graph(offline).profile(); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .network) }
        let attempts = await offline.requests.count; XCTAssertEqual(attempts, 3)
        let unauthorised = MicrosoftMockTransport([.init([:], status: 401), .init([:], status: 401)])
        do { _ = try await graph(unauthorised).profile(); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .reconnect) }
        let count = await unauthorised.requests.count; XCTAssertEqual(count, 2)
    }

    func testPartialDeltaHydrationAndChangedSourceNeedsFreshReview() async throws {
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.deltaLink": delta]),
            .init(profile), .init(["value": [["id": "m1"]], "@odata.deltaLink": delta]), .init(message(body: "Tutorial moved to 2026-10-22 16:00"))])
        let db = try LocalDatabase(); try db.save(state())
        try db.importOutlook(try await graph(transport).synchronize(account: account, previous: state(), now: now))
        try db.decideOutlook(ids: Set(try db.outlookState().proposals.map(\.id)), decision: .accepted)
        let original = try db.items()
        let saved = try db.outlookState()
        try db.importOutlook(try await graph(transport).synchronize(account: saved.accounts[0], previous: saved, now: now))
        let updated = try db.outlookState()
        XCTAssertEqual(try db.items(), original)
        XCTAssertEqual(updated.proposals.filter { !$0.withdrawn && $0.decision == .pending }.count, 1)
        let notice = try XCTUnwrap(updated.proposals.first { $0.kind == .reschedule })
        try db.decideOutlook(ids: [notice.id], decision: .accepted)
        XCTAssertEqual(try db.items(), original)
    }

    func testLocalImportFailureRollsBackCursorAndReviews() async throws {
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.deltaLink": delta])])
        let batch = try await graph(transport).synchronize(account: account, previous: state(), now: now)
        let db = try LocalDatabase(); try db.save(state())
        let source = try XCTUnwrap(batch.sources.first)
        try db.save(SourceRecord(id: "collision", provider: source.provider, externalID: source.externalID, retrievedAt: now))
        XCTAssertThrowsError(try db.importOutlook(batch))
        XCTAssertEqual(try db.outlookState(), state()); XCTAssertEqual(try db.sourceRecordCount(), 1)
    }

    func testOutlookMetadataPersistsAcrossReopenWithoutChangingCanvasProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outlook-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite").path
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.deltaLink": delta])])
        let batch = try await graph(transport).synchronize(account: account, previous: state(), now: now)
        let progress = AssignmentProgress(assignmentID: "canvas-assignment", status: .completed, updatedAt: now)
        do {
            let db = try LocalDatabase(path: path); try db.save(state()); try db.save(progress)
            try db.importOutlook(batch)
        }
        let reopened = try LocalDatabase(path: path)
        XCTAssertEqual(try reopened.outlookState().accounts[0].deltaLink, delta)
        XCTAssertEqual(try reopened.outlookState().proposals.count, 1)
        XCTAssertEqual(try reopened.assignmentProgress()[progress.assignmentID], progress)
    }

    func testCloudAnalysisIsRejectedBeforeAnyMailboxRead() async throws {
        struct CloudProvider: EmailAnalysisProvider {
            var transmitsOffDevice: Bool { true }
            func analyze(_ input: EmailAnalysisInput) async throws -> [EmailProposal] { XCTFail("Cloud provider must not run"); return [] }
        }
        let transport = MicrosoftMockTransport([])
        do { _ = try await graph(transport).synchronize(account: account, previous: state(), now: now, provider: CloudProvider()); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .permission) }
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
}

extension OutlookIntegrationTests {
    func testConflictDetectionIncludesProposedOverlapsAndChangedDeadlines() async throws {
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [
            message("a", body: "Meeting 2026-10-21 14:00", subject: "Project meeting"),
            message("b", body: "Tutorial 2026-10-21 14:30", subject: "Numerical methods"),
            message("c", body: "Meeting 2026-10-22 14:00", subject: "Project meeting")], "@odata.deltaLink": delta])])
        let db = try LocalDatabase(); try db.save(state())
        try db.importOutlook(try await graph(transport).synchronize(account: account, previous: state(), now: now))
        let proposals = try db.outlookState().proposals
        XCTAssertEqual(proposals.count, 3)
        XCTAssertTrue(proposals.allSatisfy { !$0.conflictsWith.isEmpty })
    }
    func testLongRetryAfterStopsWithoutEarlyRetry() async throws {
        let transport = MicrosoftMockTransport([.init([:], status: 429, headers: ["Retry-After": "300"])])
        do { _ = try await graph(transport).profile(); XCTFail() }
        catch { XCTAssertEqual(error as? OutlookError, .http(429)) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    func testValidTokenReuseDoesNotContactOAuthEndpoint() async throws {
        let store = MemoryMicrosoftStore(); let transport = MicrosoftMockTransport([])
        try store.save(MicrosoftCredentials(accessToken: "valid-mock", refreshToken: "refresh-mock", expiresAt: Date().addingTimeInterval(3600)), accountID: account.id)
        let session = MicrosoftSession(account: account, store: store, transport: transport)
        let value = try await session.accessToken(); XCTAssertEqual(value, "valid-mock")
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
}

extension OutlookIntegrationTests {
    func testUnchangedEvidencePreservesUserDateCorrectionAcrossMetadataUpdates() async throws {
        var updatedMessage = message(); updatedMessage["lastModifiedDateTime"] = "2026-10-19T09:00:00Z"
        let transport = MicrosoftMockTransport([.init(profile), .init(["value": [message()], "@odata.deltaLink": delta]),
            .init(profile), .init(["value": [updatedMessage], "@odata.deltaLink": delta])])
        let db = try LocalDatabase(); try db.save(state())
        try db.importOutlook(try await graph(transport).synchronize(account: account, previous: state(), now: now))
        var saved = try db.outlookState()
        let corrected = try XCTUnwrap(saved.proposals[0].date).addingTimeInterval(3600)
        saved.proposals[0].date = corrected; saved.proposals[0].durationMinutes = 90; try db.save(saved)
        try db.decideOutlook(ids: [saved.proposals[0].id], decision: .accepted)
        saved = try db.outlookState()
        try db.importOutlook(try await graph(transport).synchronize(account: saved.accounts[0], previous: saved, now: now))
        let result = try db.outlookState().proposals
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].date, corrected)
        XCTAssertEqual(result[0].durationMinutes, 90); XCTAssertEqual(result[0].decision, .accepted)
        XCTAssertEqual(try db.items()[0].startsAt, corrected)
    }
}
