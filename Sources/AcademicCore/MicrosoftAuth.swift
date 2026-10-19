import Foundation
import Security
import CryptoKit

private final class MicrosoftRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Ephemeral, cookie-free, redirect-blocking transport with a streaming response limit.
public struct MicrosoftHTTPTransport: CanvasTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: MicrosoftRedirectBlocker(), delegateQueue: nil)
    }()
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw OutlookError.invalidResponse }
        guard response.expectedContentLength <= 8_000_000 else { throw OutlookError.limit }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8_000_000 else { throw OutlookError.limit }
            data.append(byte)
        }
        return (data, response)
    }
}

public struct MicrosoftCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
}

public protocol MicrosoftCredentialStore: Sendable {
    func read(accountID: String) throws -> MicrosoftCredentials?
    func save(_ credentials: MicrosoftCredentials, accountID: String) throws
    func remove(accountID: String) throws
}

public struct MicrosoftKeychainStore: MicrosoftCredentialStore {
    public init() {}
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.academic-time-manager.microsoft",
         kSecAttrAccount as String: id]
    }
    public func read(accountID: String) throws -> MicrosoftCredentials? {
        var q = query(accountID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CanvasKeychainError.operationFailed(status) }
        guard let data = value as? Data, let credential = try? JSONDecoder().decode(MicrosoftCredentials.self, from: data) else { throw OutlookError.reconnect }
        return credential
    }
    public func save(_ credentials: MicrosoftCredentials, accountID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        var q = query(accountID); q[kSecValueData as String] = data
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(accountID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw CanvasKeychainError.operationFailed(status) }
    }
    public func remove(accountID: String) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CanvasKeychainError.operationFailed(status) }
    }
}

public struct MicrosoftAuthorization: Sendable {
    public static let redirectURI = "msauth.org.example.AcademicTimeManager://auth"
    public static let scope = "https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.Read offline_access"
    public let clientID: String
    public let verifier: String
    public let state: String
    public init(clientID: String) throws {
        guard UUID(uuidString: clientID) != nil else { throw OutlookError.configuration }
        self.clientID = clientID.lowercased()
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OutlookError.configuration }
            return Self.base64URL(Data(bytes))
        }
        verifier = try random(); state = try random()
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public var url: URL {
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = ["client_id": clientID, "response_type": "code", "redirect_uri": Self.redirectURI,
            "scope": Self.scope, "state": state, "code_challenge": Self.challenge(for: verifier),
            "code_challenge_method": "S256", "response_mode": "query", "prompt": "select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    public func code(from callback: URL) throws -> String {
        guard let c = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: Self.redirectURI), c.scheme?.lowercased() == expected.scheme?.lowercased(),
              c.host == expected.host, c.path == expected.path, c.port == nil, c.user == nil, c.password == nil, c.fragment == nil else { throw OutlookError.invalidCallback }
        let fields = c.queryItems ?? []
        func single(_ name: String) -> String? { let found = fields.filter { $0.name == name }; return found.count == 1 ? found[0].value : nil }
        guard single("state") == state else { throw OutlookError.invalidCallback }
        if single("error") != nil { throw OutlookError.permission }
        guard let code = single("code"), !code.isEmpty else { throw OutlookError.invalidCallback }
        return code
    }
}

public struct MicrosoftOAuthClient: Sendable {
    public let transport: any CanvasTransport
    public init(transport: any CanvasTransport = MicrosoftHTTPTransport()) { self.transport = transport }
    public func exchange(_ authorization: MicrosoftAuthorization, callback: URL, now: Date = Date()) async throws -> MicrosoftCredentials {
        let code = try authorization.code(from: callback)
        return try await token(fields: ["client_id": authorization.clientID, "grant_type": "authorization_code",
            "code": code, "code_verifier": authorization.verifier, "redirect_uri": MicrosoftAuthorization.redirectURI,
            "scope": MicrosoftAuthorization.scope], fallbackRefresh: nil, now: now)
    }
    public func refresh(_ credential: MicrosoftCredentials, clientID: String, now: Date = Date()) async throws -> MicrosoftCredentials {
        try await token(fields: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": credential.refreshToken,
            "scope": MicrosoftAuthorization.scope], fallbackRefresh: credential.refreshToken, now: now)
    }
    private func token(fields: [String: String], fallbackRefresh: String?, now: Date) async throws -> MicrosoftCredentials {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch { throw OutlookError.network }
        guard response.statusCode == 200 else {
            if [400, 401].contains(response.statusCode) { throw OutlookError.reconnect }
            if response.statusCode == 403 { throw OutlookError.permission }
            throw OutlookError.http(response.statusCode)
        }
        struct Tokens: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int; let token_type: String; let scope: String? }
        guard let result = try? JSONDecoder().decode(Tokens.self, from: data), !result.access_token.isEmpty,
              result.token_type.lowercased() == "bearer", result.expires_in > 0,
              let refresh = result.refresh_token ?? fallbackRefresh, !refresh.isEmpty else { throw OutlookError.invalidResponse }
        if let scopes = result.scope {
            guard scopes.split(separator: " ").contains(where: { $0 == "Mail.Read" || $0 == "https://graph.microsoft.com/Mail.Read" }) else { throw OutlookError.permission }
        }
        return MicrosoftCredentials(accessToken: result.access_token, refreshToken: refresh, expiresAt: now.addingTimeInterval(TimeInterval(result.expires_in)))
    }
}

/// One actor per account; refresh rotation is coalesced for concurrent requests.
public actor MicrosoftSession {
    private let account: OutlookAccount
    private let store: any MicrosoftCredentialStore
    private let oauth: MicrosoftOAuthClient
    private var refreshing: Task<MicrosoftCredentials, Error>?
    public init(account: OutlookAccount, store: any MicrosoftCredentialStore = MicrosoftKeychainStore(), transport: any CanvasTransport = MicrosoftHTTPTransport()) {
        self.account = account; self.store = store; oauth = MicrosoftOAuthClient(transport: transport)
    }
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if let refreshing { return try await refreshing.value.accessToken }
        guard let current = try store.read(accountID: account.id) else { throw OutlookError.reconnect }
        if !forceRefresh && current.expiresAt > Date().addingTimeInterval(120) { return current.accessToken }
        let oauth = self.oauth; let account = self.account; let store = self.store
        let task = Task {
            let updated = try await oauth.refresh(current, clientID: account.clientID)
            try store.save(updated, accountID: account.id)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }
}
