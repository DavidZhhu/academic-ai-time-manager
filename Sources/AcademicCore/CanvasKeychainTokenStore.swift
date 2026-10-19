import Foundation
import Security

public protocol CanvasTokenStoring: Sendable {
    func save(token: String) throws
    func readToken() throws -> String?
    func hasToken() throws -> Bool
    func deleteToken() throws
}

/// Stores the Oxford Canvas token in the user's file-based macOS login Keychain.
/// This app is distributed as an ad-hoc-signed local bundle, so it uses the
/// login Keychain's ACL model instead of Data Protection access groups, which
/// require app signing entitlements. Token values never enter errors or logs.
public struct KeychainCanvasTokenStore: CanvasTokenStoring {
    private let service: String
    private let account = "oxford-canvas-api-token"

    public init(service: String = "org.academic-time-manager.canvas.ox.ac.uk") {
        self.service = service
    }

    public func save(token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Self.keychainError(updateStatus) }
        } else if status != errSecSuccess {
            throw Self.keychainError(status)
        }
    }

    public func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.keychainError(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CanvasKeychainError.invalidStoredValue
        }
        return token
    }

    public func hasToken() throws -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.keychainError(status) }
        return true
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.keychainError(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainError(_ status: OSStatus) -> CanvasKeychainError {
        CanvasKeychainError.operationFailed(status)
    }
}

public enum CanvasKeychainError: Error, LocalizedError, Equatable {
    case operationFailed(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case .operationFailed(errSecMissingEntitlement): "This app build is not authorized for the requested Keychain access group. Rebuild the app with its supported Keychain configuration."
        case .operationFailed(errSecInteractionNotAllowed): "macOS could not access the login Keychain. Unlock it in Keychain Access, then try again."
        case .operationFailed(errSecAuthFailed): "macOS denied access to the login Keychain. Approve the Keychain access prompt and try again."
        case .operationFailed(let status): "The macOS Keychain operation failed (OSStatus \(status)). Check Keychain access and try again."
        case .invalidStoredValue: "The saved Canvas credential could not be read. Remove it and enter the token again."
        }
    }
}
