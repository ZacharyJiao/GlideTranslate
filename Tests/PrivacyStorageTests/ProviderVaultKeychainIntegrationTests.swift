import Foundation
import Security
import XCTest

@testable import PrivacyStorage

final class ProviderVaultKeychainIntegrationTests: XCTestCase {
    func testDisposableRandomAccountLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["GT_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Opt-in Keychain integration is disabled")
        }
        let service = "com.zaryolabs.GlideTranslate.tests.\(UUID().uuidString)"
        let account = UUID()
        let cleanupService = service
        let cleanupAccount = account
        addTeardownBlock {
            let cleanupQuery = query(
                service: cleanupService,
                account: cleanupAccount
            )
            let cleanup = SecItemDelete(cleanupQuery)
            XCTAssertTrue(
                cleanup == errSecSuccess || cleanup == errSecItemNotFound,
                "Disposable Keychain account cleanup did not converge"
            )
            XCTAssertEqual(SecItemCopyMatching(cleanupQuery, nil), errSecItemNotFound)
        }

        let store = KeychainCredentialStore(service: service)
        try await store.add(
            SensitiveCredentialInput("disposable-synthetic-credential"),
            account: account
        )
        try await store.delete(account: account)
        let cleanupQuery = query(service: service, account: account)
        XCTAssertEqual(SecItemCopyMatching(cleanupQuery, nil), errSecItemNotFound)
    }
}

private func query(service: String, account: UUID) -> CFDictionary {
    [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account.uuidString
    ] as CFDictionary
}
