import Foundation
import Security
import SharedSupport

package protocol ProviderCredentialStoring: Sendable {
    func add(
        _ credential: borrowing SensitiveCredentialInput,
        account: UUID
    ) async throws
    func delete(account: UUID) async throws
    func deleteAll() async throws
    func read(account: UUID) async throws -> Data
}

package extension ProviderCredentialStoring {
    func deleteAll() async throws {
        throw SanitizedFailure.credentialStoreUnavailable
    }
}

package struct KeychainCredentialStore: ProviderCredentialStoring {
    private let service: String

    package init(
        service: String = "com.zaryolabs.GlideTranslate.provider-credential"
    ) {
        self.service = service
    }

    package func add(
        _ credential: borrowing SensitiveCredentialInput,
        account: UUID
    ) async throws {
        let value = Data(credential.value.utf8)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.uuidString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: value
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
    }

    package func delete(account: UUID) async throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.uuidString
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
    }

    package func deleteAll() async throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
    }

    package func read(account: UUID) async throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        return data
    }
}
