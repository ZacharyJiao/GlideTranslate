import Foundation
import Security
import SharedSupport

package protocol SymmetricKeyStoring: Sendable {
    func readKey(service: String, account: String) throws -> Data?
    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial
    func deleteKey(service: String, account: String) throws
}

package struct SymmetricKeyMaterial: Sendable {
    package let data: Data
    package let createdByCaller: Bool
}

package struct SymmetricKeyStore: SymmetricKeyStoring {
    package init() {}

    package func readKey(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == 32 else {
            throw PresetStoreFailure.unrecoverable
        }
        return data
    }

    package func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        if let existing = try readKey(service: service, account: account) {
            return SymmetricKeyMaterial(data: existing, createdByCaller: false)
        }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            bytes.resetBytes(in: bytes.indices)
            throw PresetStoreFailure.encryptionFailed
        }
        let addStatus = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: bytes
        ] as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            bytes.resetBytes(in: bytes.indices)
            guard let existing = try readKey(service: service, account: account) else {
                throw PresetStoreFailure.unrecoverable
            }
            return SymmetricKeyMaterial(data: existing, createdByCaller: false)
        }
        guard addStatus == errSecSuccess else {
            bytes.resetBytes(in: bytes.indices)
            throw PresetStoreFailure.unrecoverable
        }
        return SymmetricKeyMaterial(data: bytes, createdByCaller: true)
    }

    package func deleteKey(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PresetStoreFailure.unrecoverable
        }
    }
}
