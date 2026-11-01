import Foundation
import Security

/// Where the Mac keeps its Hermes credential.
///
/// The credential is a *local* secret: it is written to the login Keychain, read at connection time
/// and never placed in a record, a log line or a transcript.
public struct HermesKeychain: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "app.neos.bridge.hermes", account: String = "local-hermes-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw HermesKeychainError(status: status, operation: "read")
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replace the stored credential. An empty value deletes it instead of storing a blank one.
    public func save(token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try clear() }
        let data = Data(trimmed.utf8)
        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw HermesKeychainError(status: updateStatus, operation: "update")
            }
            return
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HermesKeychainError(status: addStatus, operation: "add")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesKeychainError(status: status, operation: "delete")
        }
    }
}

public struct HermesKeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "keychain \(operation) failed: \(detail)"
    }
}

/// The seam the client reads its credential through, so a test can run without a Keychain.
public protocol HermesCredentialStore: Sendable {
    func token() throws -> String?
    func save(token: String) throws
    func clear() throws
}

extension HermesKeychain: HermesCredentialStore {}
