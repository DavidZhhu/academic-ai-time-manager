import Foundation

public protocol CanvasConnectionValidating: Sendable {
    func validate(token: String) async throws
}

public struct CanvasAPIConnectionValidator: CanvasConnectionValidating {
    public static let oxfordBaseURL = URL(string: "https://canvas.ox.ac.uk")!
    private let transport: any CanvasTransport

    public init(transport: any CanvasTransport = URLSessionCanvasTransport()) {
        self.transport = transport
    }

    /// Checks the credential against Canvas' current-user read endpoint. The
    /// response body is intentionally discarded and never persisted.
    public func validate(token: String) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanvasConnectionError.emptyToken
        }
        var request = URLRequest(url: Self.oxfordBaseURL.appendingPathComponent("api/v1/users/self"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (_, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw CanvasConnectionError.httpStatus(response.statusCode)
            }
        } catch let error as CanvasConnectionError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw CanvasConnectionError.offline
            case .timedOut:
                throw CanvasConnectionError.timedOut
            default:
                throw CanvasConnectionError.networkFailure
            }
        } catch {
            throw CanvasConnectionError.networkFailure
        }
    }
}

public enum CanvasConnectionError: Error, LocalizedError, Equatable {
    case emptyToken
    case httpStatus(Int)
    case offline
    case timedOut
    case networkFailure
    case noSavedToken

    public var errorDescription: String? {
        switch self {
        case .emptyToken: "Enter your Canvas API token to continue."
        case .httpStatus(401): "Canvas rejected this token. Check that it is current and was created for canvas.ox.ac.uk."
        case .httpStatus(403): "Canvas recognized the token but denied access to the validation endpoint. Check the token's permissions or Oxford Canvas access."
        case .httpStatus(429): "Canvas is temporarily rate limiting requests. Wait a little, then test again."
        case .httpStatus(let code) where code >= 500: "Oxford Canvas is temporarily unavailable (HTTP \(code)). Try again later."
        case .httpStatus(let code): "Canvas could not validate the connection (HTTP \(code)). Check the token and try again."
        case .offline: "Could not reach Oxford Canvas. Check your internet connection and try again."
        case .timedOut: "Oxford Canvas did not respond in time. Try again."
        case .networkFailure: "A network error prevented the Canvas connection check. Try again."
        case .noSavedToken: "No Canvas token is saved. Enter a token first."
        }
    }
}

/// Coordinates secure local storage and an explicit, read-only connection check.
public struct CanvasConnectionService: Sendable {
    private let tokenStore: any CanvasTokenStoring
    private let validator: any CanvasConnectionValidating

    public init(tokenStore: any CanvasTokenStoring = KeychainCanvasTokenStore(), validator: any CanvasConnectionValidating = CanvasAPIConnectionValidator()) {
        self.tokenStore = tokenStore
        self.validator = validator
    }

    public func saveAndValidate(token: String) async throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw CanvasConnectionError.emptyToken }
        try tokenStore.save(token: normalized)
        try await validator.validate(token: normalized)
    }

    public func validateSavedToken() async throws {
        guard let token = try tokenStore.readToken(), !token.isEmpty else { throw CanvasConnectionError.noSavedToken }
        try await validator.validate(token: token)
    }

    public func hasSavedToken() throws -> Bool { try tokenStore.hasToken() }
    public func disconnect() throws { try tokenStore.deleteToken() }
}
