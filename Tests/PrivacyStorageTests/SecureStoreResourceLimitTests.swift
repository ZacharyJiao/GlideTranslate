import Foundation
import CryptoKit
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class SecureStoreResourceLimitTests: XCTestCase {
    func testRegularFileReaderAcceptsExactLimitAndRejectsLimitPlusOne() throws {
        let root = resourcePhysicalTemporaryDirectory().appendingPathComponent(
            "GlideTranslate-resource-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = root.appendingPathComponent("authority.plist")
        let maximum = 512 * 1_024
        try Data(repeating: 0xa5, count: maximum).write(to: file)

        XCTAssertEqual(
            try SecureStoreFileReader.readRegularFileIfPresent(
                at: file,
                maximumByteCount: maximum
            )?.count,
            maximum
        )

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(maximum + 1))
        try handle.close()
        XCTAssertThrowsError(
            try SecureStoreFileReader.readRegularFileIfPresent(
                at: file,
                maximumByteCount: maximum
            )
        )
    }

    func testDecodedPreferenceAndProviderCollectionsAndStringsAreBounded() throws {
        var preferences = PreferencesSnapshot.defaultValue
        preferences.generalAutomaticApplications = Set((0...10_000).map {
            ApplicationIdentity(
                bundleIdentifier: "com.example.application.\($0)",
                displayName: "Application \($0)"
            )
        })
        XCTAssertThrowsError(try preferences.validated())

        let oversizedModel = String(
            repeating: "m",
            count: PrivacyStorageResourceLimits.providerModelUTF8Bytes + 1
        )
        let record = ProviderConfigurationRecord(
            id: ProviderConfigurationID(),
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: oversizedModel,
            confirmedClass: nil,
            configurationRevision: 1,
            confirmationRevision: 0,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active
        )
        XCTAssertThrowsError(try ProviderMetadataEnvelope(
            version: ProviderMetadataEnvelope.currentVersion,
            records: [record],
            offDeviceAuthorizations: [record.id: []]
        ).validated())
    }

    func testEveryStoreWiresItsOwnPredecodeCeiling() async throws {
        let root = resourcePhysicalTemporaryDirectory().appendingPathComponent(
            "GlideTranslate-store-ceilings-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        var preferences = PreferencesSnapshot.defaultValue
        preferences.generalAutomaticApplications = Set((0..<2_000).map {
            ApplicationIdentity(
                bundleIdentifier: "com.example.preferences.\($0)",
                displayName: String(repeating: "p", count: 300) + "\($0)"
            )
        })
        let preferencesData = try encoder.encode(PreferencesEnvelope(
            version: PreferencesEnvelope.currentVersion,
            snapshot: preferences
        ))
        XCTAssertGreaterThan(
            preferencesData.count,
            PrivacyStorageResourceLimits.preferencesEncodedBytes
        )
        let preferencesURL = root.appendingPathComponent("preferences.plist")
        try preferencesData.write(to: preferencesURL)
        let preferencesStore = AtomicPreferencesStore.openResettable(
            fileURL: preferencesURL,
            offDeviceAuthorizationReconciler: ResourceNoOpReconciler()
        )
        do {
            _ = try await preferencesStore.snapshot()
            XCTFail("preferences caller must apply its predecode ceiling")
        } catch {}

        let providerID = ProviderConfigurationID()
        let providerApplications = Set((0..<4_000).map {
            ApplicationIdentity(
                bundleIdentifier: "com.example.provider.\($0)",
                displayName: String(repeating: "v", count: 600) + "\($0)"
            )
        })
        let providerRecord = ProviderConfigurationRecord(
            id: providerID,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "bounded",
            confirmedClass: .cloud,
            configurationRevision: 1,
            confirmationRevision: 1,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active
        )
        let providerData = try encoder.encode(ProviderMetadataEnvelope(
            version: ProviderMetadataEnvelope.currentVersion,
            records: [providerRecord],
            offDeviceAuthorizations: [providerID: providerApplications]
        ))
        XCTAssertGreaterThan(
            providerData.count,
            PrivacyStorageResourceLimits.providerMetadataEncodedBytes
        )
        let providerURL = root.appendingPathComponent("providers.plist")
        try providerData.write(to: providerURL)
        let repository = ProviderMetadataRepository(fileURL: providerURL)
        do {
            _ = try await repository.load()
            XCTFail("provider caller must apply its predecode ceiling")
        } catch {}

        let presets = (0..<100).map { index in
            let suffix = String(format: "%010d", index)
            return CustomPreset(
                id: .custom(),
                name: String(repeating: "🧪", count: 70) + suffix,
                explanation: String(repeating: "🧪", count: 7_990) + suffix,
                template: String(repeating: "🧪", count: 7_984)
                    + "{text}" + suffix,
                targetLanguage: .identified("en"),
                action: .translate
            )
        }
        var plaintext = try encoder.encode(presets)
        defer { plaintext.resetBytes(in: plaintext.indices) }
        let keyData = Data(repeating: 0x5a, count: 32)
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: Data("glidetranslate.private-presets.v1".utf8)
        )
        let presetData = try encoder.encode(PresetEnvelope(
            version: 1,
            sealedCombined: try XCTUnwrap(box.combined)
        ))
        XCTAssertGreaterThan(
            presetData.count,
            PrivacyStorageResourceLimits.customPresetsEncodedBytes
        )
        let presetURL = root.appendingPathComponent("private-presets.plist")
        try presetData.write(to: presetURL)
        let presetStore = EncryptedCustomPresetPersistence.openResettable(
            fileURL: presetURL,
            keyStore: ResourceStaticKeyStore(keyData: keyData),
            service: "com.example.resource.private-presets-key"
        )
        do {
            _ = try await presetStore.customPresets()
            XCTFail("preset caller must apply its predecode ceiling")
        } catch {}
    }
}

private actor ResourceNoOpReconciler: OffDeviceAuthorizationReconciling {
    func reconcileOffDeviceAuthorizations(
        withGeneralAllowlistCeiling: Set<ApplicationIdentity>
    ) async throws {}
}

private final class ResourceStaticKeyStore: SymmetricKeyStoring,
    @unchecked Sendable {
    let keyData: Data

    init(keyData: Data) { self.keyData = keyData }

    func readKey(service: String, account: String) throws -> Data? { keyData }

    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        SymmetricKeyMaterial(data: keyData, createdByCaller: false)
    }

    func deleteKey(service: String, account: String) throws {}
}

private func resourcePhysicalTemporaryDirectory() -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(temporaryPath, nil) else {
        return FileManager.default.temporaryDirectory
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}
