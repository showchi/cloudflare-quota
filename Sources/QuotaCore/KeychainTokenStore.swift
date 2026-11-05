import Foundation
import Security

public struct KeychainTokenStore: TokenStoring {
    public var service: String

    public init(service: String = "app.cloudflare-quota.tokens") {
        self.service = service
    }

    public func token(for accountID: UUID) throws -> String? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status)
        }
        return token
    }

    public func save(token: String, for accountID: UUID) throws {
        let data = Data(token.utf8)
        let query = baseQuery(accountID) as CFDictionary
        let update = [kSecValueData as String: data] as CFDictionary
        let existing = SecItemUpdate(query, update)
        if existing == errSecSuccess {
            return
        }
        if existing != errSecItemNotFound {
            throw KeychainError.status(existing)
        }
        var insert = baseQuery(accountID)
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    public func deleteToken(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(_ accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public var status: OSStatus

    public static func status(_ status: OSStatus) -> KeychainError {
        KeychainError(status: status)
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return L10n.format(.keychainFailed, status)
    }
}
