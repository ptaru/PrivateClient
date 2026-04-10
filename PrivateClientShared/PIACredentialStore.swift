import Foundation
import Security

protocol PIACredentialStore {
    func loadCredentials() throws -> StoredCredentials?
    func saveCredentials(_ credentials: StoredCredentials) throws
    func deleteCredentials() throws
    func loadToken() throws -> PIAAuthToken?
    func saveToken(_ token: PIAAuthToken) throws
    func deleteToken() throws
}

struct StoredCredentials: Codable, Equatable, Sendable {
    let username: String
    let password: String
}

final class KeychainPIACredentialStore: PIACredentialStore {
    private enum Key {
        static let credentialsService = "uk.tarun.PrivateClient.credentials"
        static let tokenService = "uk.tarun.PrivateClient.token"
        static let account = "default"
    }

    func loadCredentials() throws -> StoredCredentials? {
        guard let data = try readItem(service: Key.credentialsService) else {
            return nil
        }
        return try JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    func saveCredentials(_ credentials: StoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try writeItem(data, service: Key.credentialsService)
    }

    func deleteCredentials() throws {
        try deleteItem(service: Key.credentialsService)
    }

    func loadToken() throws -> PIAAuthToken? {
        guard let data = try readItem(service: Key.tokenService) else {
            return nil
        }
        return try JSONDecoder().decode(PIAAuthToken.self, from: data)
    }

    func saveToken(_ token: PIAAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        try writeItem(data, service: Key.tokenService)
    }

    func deleteToken() throws {
        try deleteItem(service: Key.tokenService)
    }
}

private extension KeychainPIACredentialStore {
    func readItem(service: String) throws -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.security(status)
        }
    }

    func writeItem(_ data: Data, service: String) throws {
        let query = baseQuery(service: service)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.security(updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw CredentialStoreError.security(status)
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw CredentialStoreError.security(insertStatus)
        }
    }

    func deleteItem(service: String) throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.security(status)
        }
    }

    func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Key.account
        ]
    }
}

enum CredentialStoreError: LocalizedError {
    case security(OSStatus)

    var errorDescription: String? {
        switch self {
        case .security(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
