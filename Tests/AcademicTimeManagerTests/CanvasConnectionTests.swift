import Foundation
import XCTest
@testable import AcademicCore

private actor CanvasConnectionFixtureTransport: CanvasTransport {
    private let status: Int
    private var captured: URLRequest?

    init(status: Int) { self.status = status }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data("ignored fixture body".utf8), response)
    }

    func request() -> URLRequest? { captured }
}

private final class MemoryCanvasTokenStore: CanvasTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func save(token: String) throws { lock.lock(); defer { lock.unlock() }; value = token }
    func readToken() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func hasToken() throws -> Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    func deleteToken() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

private struct RecordingCanvasValidator: CanvasConnectionValidating {
    let result: Result<Void, CanvasConnectionError>
    func validate(token: String) async throws { try result.get() }
}

final class CanvasConnectionTests: XCTestCase {
    func testValidationUsesOxfordHTTPSReadOnlyEndpointAndBearerHeader() async throws {
        let transport = CanvasConnectionFixtureTransport(status: 200)
        let validator = CanvasAPIConnectionValidator(transport: transport)
        try await validator.validate(token: "mock-canvas-token-for-tests")

        let request = await transport.request()
        XCTAssertEqual(request?.url?.absoluteString, "https://canvas.ox.ac.uk/api/v1/users/self")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer mock-canvas-token-for-tests")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(request?.httpBody)
    }

    func testConnectionErrorsAreMeaningfulWithoutIncludingCredential() async throws {
        let cases: [(Int, String)] = [
            (401, "Canvas rejected this token"),
            (403, "denied access"),
            (429, "rate limiting"),
            (503, "temporarily unavailable")
        ]
        for (status, message) in cases {
            let validator = CanvasAPIConnectionValidator(transport: CanvasConnectionFixtureTransport(status: status))
            do {
                try await validator.validate(token: "mock-secret-value")
                XCTFail("Expected HTTP \(status) to fail validation")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(message))
                XCTAssertFalse(error.localizedDescription.contains("mock-secret-value"))
            }
        }
    }

    func testEmptyTokenIsRejectedBeforeStorageOrNetworkValidation() async throws {
        let store = MemoryCanvasTokenStore()
        let service = CanvasConnectionService(tokenStore: store, validator: RecordingCanvasValidator(result: .success(())))
        do {
            try await service.saveAndValidate(token: " \n ")
            XCTFail("Expected an empty token to be rejected")
        } catch {
            XCTAssertEqual(error as? CanvasConnectionError, .emptyToken)
        }
        XCTAssertFalse(try store.hasToken())
    }

    func testServiceSavesAndValidatesTokenAndCanDisconnect() async throws {
        let store = MemoryCanvasTokenStore()
        let service = CanvasConnectionService(tokenStore: store, validator: RecordingCanvasValidator(result: .success(())))
        try await service.saveAndValidate(token: "  mock-token-for-tests  ")
        XCTAssertEqual(try store.readToken(), "mock-token-for-tests")
        XCTAssertTrue(try service.hasSavedToken())
        try service.disconnect()
        XCTAssertFalse(try service.hasSavedToken())
    }

    func testValidationFailureDoesNotExposeTokenAndLeavesSavedTokenAvailableForRetry() async throws {
        let store = MemoryCanvasTokenStore()
        let service = CanvasConnectionService(tokenStore: store, validator: RecordingCanvasValidator(result: .failure(.httpStatus(401))))
        do {
            try await service.saveAndValidate(token: "mock-secret-value")
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("mock-secret-value"))
        }
        XCTAssertEqual(try store.readToken(), "mock-secret-value")
    }

    func testSavedTokenValidationRequiresSavedCredential() async throws {
        let service = CanvasConnectionService(tokenStore: MemoryCanvasTokenStore(), validator: RecordingCanvasValidator(result: .success(())))
        do {
            try await service.validateSavedToken()
            XCTFail("Expected missing token error")
        } catch {
            XCTAssertEqual(error as? CanvasConnectionError, .noSavedToken)
        }
    }

    func testKeychainErrorsExplainEntitlementAndAuthorizationFailuresWithoutSecrets() {
        let missingEntitlement = CanvasKeychainError.operationFailed(-34018).localizedDescription
        XCTAssertTrue(missingEntitlement.contains("Keychain access group"))
        XCTAssertFalse(missingEntitlement.contains("mock-secret-value"))

        let interactionDenied = CanvasKeychainError.operationFailed(-25308).localizedDescription
        XCTAssertTrue(interactionDenied.localizedCaseInsensitiveContains("login Keychain"))
    }
}
