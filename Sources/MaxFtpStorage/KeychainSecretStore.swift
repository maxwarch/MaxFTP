import Foundation
import MaxFtpCore
import Security

/// Secrets stockés dans le trousseau macOS (éléments « mot de passe générique »).
public struct KeychainSecretStore: SecretStore {
    public struct KeychainError: LocalizedError {
        public let status: OSStatus

        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
            return "Trousseau : \(message)"
        }
    }

    private let service: String

    public init(service: String = "com.maxftp.app") {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "MaxFtp"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
