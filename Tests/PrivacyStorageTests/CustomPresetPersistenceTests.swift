import CryptoKit
import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class CustomPresetPersistenceTests: XCTestCase {
    func testMissingFileAndKeyIsEmptyWithoutCreatingEither() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }

        let values = try await fixture.persistence.customPresets()

        XCTAssertEqual(values, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keys.storedKey)
        XCTAssertEqual(fixture.keys.reads, [
            PresetKeyIdentity.expected,
            PresetKeyIdentity.expected
        ])
        XCTAssertEqual(fixture.keys.creations, [])
    }

    func testFirstWriteReopenEncryptsPrivateFieldsAndUsesExactKeyIdentity() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }

        try await fixture.persistence.save(.privateFixture)
        let reopened = try fixture.reopen()

        let reopenedValues = try await reopened.customPresets()
        XCTAssertEqual(reopenedValues, [.privateFixture])
        let bytes = try Data(contentsOf: fixture.fileURL)
        XCTAssertTrue(bytes.starts(with: Data("bplist00".utf8)))
        for plaintext in CustomPreset.privateFixture.plaintextFields {
            XCTAssertNil(bytes.range(of: Data(plaintext.utf8)))
        }
        XCTAssertEqual(presetFileMode(fixture.fileURL), 0o600)
        XCTAssertEqual(fixture.keys.creations, [PresetKeyIdentity.expected])
        XCTAssertEqual(fixture.keys.reads, [
            PresetKeyIdentity.expected,
            PresetKeyIdentity.expected,
            PresetKeyIdentity.expected,
            PresetKeyIdentity.expected
        ])
    }

    func testSavingIdenticalPresetTwiceUsesUniqueNonceAndReplacementReopens() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }
        try await fixture.persistence.save(.privateFixture)
        let first = try outerEnvelope(at: fixture.fileURL).sealedCombined

        try await fixture.persistence.save(.privateFixture)
        let second = try outerEnvelope(at: fixture.fileURL).sealedCombined

        XCTAssertNotEqual(first, second)
        let reopenedValues = try await fixture.reopen().customPresets()
        XCTAssertEqual(reopenedValues, [.privateFixture])
    }

    func testStableAADOpensExternallySealedEnvelope() async throws {
        let fixture = try PresetPersistenceFixture.encryptedRaw([.privateFixture])
        defer { fixture.remove() }

        let values = try await fixture.reopen().customPresets()

        XCTAssertEqual(values, [.privateFixture])
    }

    func testTamperMissingKeyUnknownVersionAndMissingFileWithKeyAreUnrecoverable() async throws {
        let tampered = try await PresetPersistenceFixture.withSavedPreset()
        defer { tampered.remove() }
        let original = try Data(contentsOf: tampered.fileURL)
        try tampered.flipCiphertextByte()
        let tamperedBytes = try Data(contentsOf: tampered.fileURL)
        await assertPresetFailure(.unrecoverable) { _ = try tampered.reopen() }
        XCTAssertNotEqual(tamperedBytes, original)
        XCTAssertEqual(try Data(contentsOf: tampered.fileURL), tamperedBytes)

        let missingKey = try await PresetPersistenceFixture.withSavedPreset()
        defer { missingKey.remove() }
        missingKey.keys.removeKey()
        await assertPresetFailure(.unrecoverable) { _ = try missingKey.reopen() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingKey.fileURL.path))

        let unknown = try await PresetPersistenceFixture.withSavedPreset()
        defer { unknown.remove() }
        var envelope = try outerEnvelope(at: unknown.fileURL)
        envelope.version = 2
        try writeOuterEnvelope(envelope, to: unknown.fileURL)
        let unknownBytes = try Data(contentsOf: unknown.fileURL)
        await assertPresetFailure(.unrecoverable) { _ = try unknown.reopen() }
        XCTAssertEqual(try Data(contentsOf: unknown.fileURL), unknownBytes)

        let keyWithoutFile = try PresetPersistenceFixture.keyWithoutFile()
        defer { keyWithoutFile.remove() }
        await assertPresetFailure(.unrecoverable) { _ = try keyWithoutFile.reopen() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyWithoutFile.fileURL.path))
    }

    func testFailedFirstAndReplacementInstallsPreserveDefinedAuthority() async throws {
        let firstFailure = try PresetPersistenceFixture.empty(
            installer: FailPresetInstallNumber(1)
        )
        defer { firstFailure.remove() }
        await assertPresetFailure(.unrecoverable) {
            try await firstFailure.persistence.save(.privateFixture)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFailure.fileURL.path))
        XCTAssertNil(firstFailure.keys.storedKey)
        let firstFailureValues = try await firstFailure.persistence.customPresets()
        let firstFailureReopenedValues = try await firstFailure.reopen().customPresets()
        XCTAssertEqual(firstFailureValues, [])
        XCTAssertEqual(firstFailureReopenedValues, [])

        let replacementFailure = try PresetPersistenceFixture.empty(
            installer: FailPresetInstallNumber(2)
        )
        defer { replacementFailure.remove() }
        try await replacementFailure.persistence.save(.privateFixture)
        let oldBytes = try Data(contentsOf: replacementFailure.fileURL)
        await assertPresetFailure(.unrecoverable) {
            try await replacementFailure.persistence.save(.secondFixture)
        }
        XCTAssertEqual(try Data(contentsOf: replacementFailure.fileURL), oldBytes)
        let memoryValues = try await replacementFailure.persistence.customPresets()
        let diskValues = try await replacementFailure.reopen().customPresets()
        XCTAssertEqual(memoryValues, [.privateFixture])
        XCTAssertEqual(diskValues, [.privateFixture])
    }

    func testDeleteResealsRemainingAndRejectsBuiltInOrMissingIDs() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }
        try await fixture.persistence.save(.privateFixture)
        try await fixture.persistence.save(.secondFixture)
        let beforeDelete = try outerEnvelope(at: fixture.fileURL).sealedCombined

        try await fixture.persistence.delete(CustomPreset.privateFixture.id)
        let afterDelete = try outerEnvelope(at: fixture.fileURL).sealedCombined

        XCTAssertNotEqual(beforeDelete, afterDelete)
        let reopenedValues = try await fixture.reopen().customPresets()
        XCTAssertEqual(reopenedValues, [.secondFixture])
        await assertPromptFailure(.immutableBuiltIn) {
            try await fixture.persistence.delete(PresetID(rawValue: "accurate-translation"))
        }
        await assertPromptFailure(.presetNotFound) {
            try await fixture.persistence.delete(PresetID.custom())
        }
    }

    func testSaveRejectsBuiltInMalformedIdentifierAndRepresentationBoundsBeforeInstall() async throws {
        let installer = CountingPresetInstaller()
        let fixture = try PresetPersistenceFixture.empty(installer: installer)
        defer { fixture.remove() }
        var builtIn = CustomPreset.privateFixture
        builtIn = builtIn.replacingID(PresetID(rawValue: "accurate-translation"))
        await assertPromptFailure(.immutableBuiltIn) {
            try await fixture.persistence.save(builtIn)
        }
        for malformedID in [
            "custom-not-a-uuid",
            "custom-11111111-1111-1111-1111-11111111111A",
            "custom-{11111111-1111-1111-1111-111111111111}",
            "custom-11111111111111111111111111111111"
        ] {
            let malformed = CustomPreset.privateFixture.replacingID(
                PresetID(rawValue: malformedID)
            )
            await assertPromptFailure(.invalidCustomIdentifier) {
                try await fixture.persistence.save(malformed)
            }
        }

        for invalid in [
            CustomPreset.privateFixture.replacingName(String(repeating: "n", count: 81)),
            CustomPreset.privateFixture.replacingExplanation(String(repeating: "e", count: 8_001)),
            CustomPreset.privateFixture.replacingTemplate(String(repeating: "t", count: 8_001))
        ] {
            await assertPresetFailure(.invalidRepresentation) {
                try await fixture.persistence.save(invalid)
            }
        }
        XCTAssertEqual(installer.calls, 0)
        XCTAssertNil(fixture.keys.storedKey)
    }

    func testInclusiveRepresentationAndCountBoundsAreAccepted() async throws {
        let boundary = CustomPreset.privateFixture
            .replacingName(String(repeating: "n", count: 80))
            .replacingExplanation(String(repeating: "e", count: 8_000))
            .replacingTemplate(String(repeating: "t", count: 7_994) + "{text}")
        let fixture = try PresetPersistenceFixture.encryptedRaw(
            [boundary] + (1..<100).map { CustomPreset.numbered($0) }
        )
        defer { fixture.remove() }

        let reopened = try fixture.reopen()
        let values = try await reopened.customPresets()

        XCTAssertEqual(values.count, 100)
        XCTAssertEqual(values.first, boundary)
        let originalBytes = try Data(contentsOf: fixture.fileURL)
        await assertPresetFailure(.invalidRepresentation) {
            try await reopened.save(.numbered(100))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), originalBytes)
    }

    func testMalformedStoredIdentifierAndRepresentationAreUnrecoverable() async throws {
        let malformedID = CustomPreset.privateFixture.replacingID(
            PresetID(rawValue: "custom-{11111111-1111-1111-1111-111111111111}")
        )
        let oversized = CustomPreset.privateFixture.replacingName(
            String(repeating: "n", count: 81)
        )

        for presets in [[malformedID], [oversized]] {
            let fixture = try PresetPersistenceFixture.encryptedRaw(presets)
            defer { fixture.remove() }
            await assertPresetFailure(.unrecoverable) { _ = try fixture.reopen() }
        }
    }

    func testTwoOpenActorsReloadCurrentAuthorityBeforeReadAndMutation() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }
        let second = try fixture.reopen()

        try await fixture.persistence.save(.privateFixture)
        let valuesObservedBySecond = try await second.customPresets()
        XCTAssertEqual(valuesObservedBySecond, [.privateFixture])

        try await second.save(.secondFixture)
        let valuesObservedByFirst = try await fixture.persistence.customPresets()
        let reopenedValues = try await fixture.reopen().customPresets()
        XCTAssertEqual(valuesObservedByFirst, [.privateFixture, .secondFixture])
        XCTAssertEqual(reopenedValues, [.privateFixture, .secondFixture])
    }

    func testPostOpenTamperCannotBeOverwrittenFromCachedAuthority() async throws {
        let fixture = try await PresetPersistenceFixture.withSavedPreset()
        defer { fixture.remove() }
        let stale = try fixture.reopen()
        try fixture.flipCiphertextByte()
        let corruptedBytes = try Data(contentsOf: fixture.fileURL)

        await assertPresetFailure(.unrecoverable) {
            try await stale.save(.secondFixture)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corruptedBytes)
    }

    func testEstablishedAuthorityRemovalPoisonsActorWithoutRecreatingIt() async throws {
        let fixture = try await PresetPersistenceFixture.withSavedPreset()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.fileURL)
        fixture.keys.removeKey()

        await assertPresetFailure(.unrecoverable) {
            _ = try await fixture.persistence.customPresets()
        }
        await assertPresetFailure(.unrecoverable) {
            try await fixture.persistence.save(.secondFixture)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keys.storedKey)
    }

    func testStaleWriterFailureDoesNotDeleteCommittedAuthorityKey() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }
        let stale = try fixture.reopen(installer: FailPresetInstallNumber(1))
        try await fixture.persistence.save(.privateFixture)

        await assertPresetFailure(.unrecoverable) {
            try await stale.save(.secondFixture)
        }

        XCTAssertNotNil(fixture.keys.storedKey)
        let reopenedValues = try await fixture.reopen().customPresets()
        XCTAssertEqual(reopenedValues, [.privateFixture])
    }

    func testConcurrentFirstWritesSerializeAndMergeAuthority() async throws {
        let fixture = try PresetPersistenceFixture.empty()
        defer { fixture.remove() }
        let second = try fixture.reopen()

        async let firstWrite: Void = fixture.persistence.save(.privateFixture)
        async let secondWrite: Void = second.save(.secondFixture)
        _ = try await (firstWrite, secondWrite)

        let values = try await fixture.reopen().customPresets()
        XCTAssertEqual(Set(values.map(\.id)), Set([
            CustomPreset.privateFixture.id,
            CustomPreset.secondFixture.id
        ]))
    }

    func testDurabilityUncertaintyReloadsFirstAndReplacementAuthority() async throws {
        let uncertainInstaller = SameDirectoryAtomicInstaller(
            hooks: AtomicInstallerHooks(failDirectorySync: true)
        )
        let first = try PresetPersistenceFixture.empty(installer: uncertainInstaller)
        defer { first.remove() }
        await assertPresetFailure(.unrecoverable) {
            try await first.persistence.save(.privateFixture)
        }
        let firstValues = try await first.persistence.customPresets()
        XCTAssertEqual(firstValues, [.privateFixture])

        let replacement = try PresetPersistenceFixture.empty()
        defer { replacement.remove() }
        try await replacement.persistence.save(.privateFixture)
        let uncertainReplacement = try replacement.reopen(
            installer: uncertainInstaller
        )
        await assertPresetFailure(.unrecoverable) {
            try await uncertainReplacement.save(.secondFixture)
        }
        let replacementValues = try await uncertainReplacement.customPresets()
        let reopenedValues = try await replacement.reopen().customPresets()
        XCTAssertEqual(replacementValues, [.privateFixture, .secondFixture])
        XCTAssertEqual(reopenedValues, [.privateFixture, .secondFixture])
    }

    func testDurabilityUncertaintyCannotForgetRemovedEstablishedAuthority() async throws {
        let fixture = try await PresetPersistenceFixture.withSavedPreset()
        defer { fixture.remove() }
        let persistence = try fixture.reopen(
            installer: RemoveAuthorityThenUncertainPresetInstaller(keys: fixture.keys)
        )

        await assertPresetFailure(.unrecoverable) {
            try await persistence.save(.secondFixture)
        }
        await assertPresetFailure(.unrecoverable) {
            _ = try await persistence.customPresets()
        }
        await assertPresetFailure(.unrecoverable) {
            try await persistence.save(.secondFixture)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keys.storedKey)
    }

    func testDurabilityReloadFailurePoisonsActor() async throws {
        let fixture = try PresetPersistenceFixture.empty(
            installer: CorruptThenUncertainPresetInstaller()
        )
        defer { fixture.remove() }

        await assertPresetFailure(.unrecoverable) {
            try await fixture.persistence.save(.privateFixture)
        }
        await assertPresetFailure(.unrecoverable) {
            _ = try await fixture.persistence.customPresets()
        }
    }

    func testNewKeyCleanupFailurePoisonsActor() async throws {
        let keys = MemorySymmetricKeyStore(deleteFails: true)
        let fixture = try PresetPersistenceFixture.empty(
            installer: FailPresetInstallNumber(1),
            keys: keys
        )
        defer { fixture.remove() }

        await assertPresetFailure(.unrecoverable) {
            try await fixture.persistence.save(.privateFixture)
        }
        XCTAssertNotNil(keys.storedKey)
        await assertPresetFailure(.unrecoverable) {
            _ = try await fixture.persistence.customPresets()
        }
    }

    func testDuplicateIDsAndMoreThanOneHundredStoredPresetsAreUnrecoverable() async throws {
        for presets in [
            [CustomPreset.privateFixture, CustomPreset.privateFixture],
            (0...100).map { CustomPreset.numbered($0) }
        ] {
            let fixture = try PresetPersistenceFixture.encryptedRaw(presets)
            defer { fixture.remove() }
            await assertPresetFailure(.unrecoverable) { _ = try fixture.reopen() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        }
    }
}

private struct PresetKeyIdentity: Equatable {
    let service: String
    let account: String

    static let expected = Self(
        service: "com.zaryolabs.GlideTranslate.private-presets-key",
        account: "v1"
    )
}

private struct PresetPersistenceFixture {
    let directory: URL
    let fileURL: URL
    let keys: MemorySymmetricKeyStore
    let installer: any AtomicDataInstalling
    let persistence: EncryptedCustomPresetPersistence

    static func empty(
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        keys: MemorySymmetricKeyStore = MemorySymmetricKeyStore()
    ) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideTranslate-T8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = directory.appendingPathComponent("private-presets.plist")
        return Self(
            directory: directory,
            fileURL: fileURL,
            keys: keys,
            installer: installer,
            persistence: try EncryptedCustomPresetPersistence.open(
                fileURL: fileURL,
                keyStore: keys,
                installer: installer
            )
        )
    }

    static func withSavedPreset() async throws -> Self {
        let fixture = try empty()
        try await fixture.persistence.save(.privateFixture)
        return fixture
    }

    static func keyWithoutFile() throws -> Self {
        let fixture = try empty()
        fixture.keys.installFixtureKey()
        return fixture
    }

    static func encryptedRaw(_ presets: [CustomPreset]) throws -> Self {
        let fixture = try empty()
        fixture.keys.installFixtureKey()
        var plaintext = try PropertyListEncoder().encode(presets)
        defer { plaintext.resetBytes(in: plaintext.indices) }
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: MemorySymmetricKeyStore.fixtureKey),
            authenticating: Data("glidetranslate.private-presets.v1".utf8)
        )
        try writeOuterEnvelope(
            MutablePresetEnvelope(version: 1, sealedCombined: box.combined!),
            to: fixture.fileURL
        )
        return fixture
    }

    func reopen(
        installer: (any AtomicDataInstalling)? = nil
    ) throws -> EncryptedCustomPresetPersistence {
        try EncryptedCustomPresetPersistence.open(
            fileURL: fileURL,
            keyStore: keys,
            installer: installer ?? self.installer
        )
    }

    func flipCiphertextByte() throws {
        var envelope = try outerEnvelope(at: fileURL)
        envelope.sealedCombined[envelope.sealedCombined.count / 2] ^= 0x01
        try writeOuterEnvelope(envelope, to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MemorySymmetricKeyStore:
    SymmetricKeyStoring,
    @unchecked Sendable {
    static let fixtureKey = Data((0..<32).map(UInt8.init))
    private let lock = NSLock()
    private var key: Data?
    private var readValues: [PresetKeyIdentity] = []
    private var creationValues: [PresetKeyIdentity] = []
    private let deleteFails: Bool

    init(key: Data? = nil, deleteFails: Bool = false) {
        self.key = key
        self.deleteFails = deleteFails
    }

    var storedKey: Data? { lock.withLock { key } }
    var reads: [PresetKeyIdentity] { lock.withLock { readValues } }
    var creations: [PresetKeyIdentity] { lock.withLock { creationValues } }

    func readKey(service: String, account: String) throws -> Data? {
        lock.withLock {
            readValues.append(.init(service: service, account: account))
            return key
        }
    }

    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        lock.withLock {
            creationValues.append(.init(service: service, account: account))
            if let key {
                return SymmetricKeyMaterial(data: key, createdByCaller: false)
            }
            key = Self.fixtureKey
            return SymmetricKeyMaterial(
                data: Self.fixtureKey,
                createdByCaller: true
            )
        }
    }

    func deleteKey(service: String, account: String) throws {
        try lock.withLock {
            if deleteFails { throw PresetStoreFailure.unrecoverable }
            key = nil
        }
    }

    func removeKey() { lock.withLock { key = nil } }
    func installFixtureKey() { lock.withLock { key = Self.fixtureKey } }
}

private final class CountingPresetInstaller: AtomicDataInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func install(_ data: Data, at destination: URL) throws {
        lock.withLock { count += 1 }
        try SameDirectoryAtomicInstaller().install(data, at: destination)
    }
}

private final class FailPresetInstallNumber: AtomicDataInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let failureNumber: Int
    private var count = 0
    init(_ failureNumber: Int) { self.failureNumber = failureNumber }
    func install(_ data: Data, at destination: URL) throws {
        let shouldFail = lock.withLock {
            count += 1
            return count == failureNumber
        }
        if shouldFail { throw AtomicInstallFailure.writeFailed }
        try SameDirectoryAtomicInstaller().install(data, at: destination)
    }
}

private struct CorruptThenUncertainPresetInstaller: AtomicDataInstalling {
    func install(_ data: Data, at destination: URL) throws {
        try Data([0x00]).write(to: destination)
        throw AtomicInstallFailure.durabilityUncertain
    }
}

private struct RemoveAuthorityThenUncertainPresetInstaller: AtomicDataInstalling {
    let keys: MemorySymmetricKeyStore

    func install(_ data: Data, at destination: URL) throws {
        try FileManager.default.removeItem(at: destination)
        keys.removeKey()
        throw AtomicInstallFailure.durabilityUncertain
    }
}

private struct MutablePresetEnvelope: Codable {
    var version: UInt16
    var sealedCombined: Data
}

private func outerEnvelope(at url: URL) throws -> MutablePresetEnvelope {
    try PropertyListDecoder().decode(
        MutablePresetEnvelope.self,
        from: Data(contentsOf: url)
    )
}

private func writeOuterEnvelope(_ envelope: MutablePresetEnvelope, to url: URL) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(envelope).write(to: url)
}

private func presetFileMode(_ url: URL) -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return 0 }
    return value.st_mode & mode_t(0o777)
}

private func assertPresetFailure(
    _ expected: PresetStoreFailure,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected preset store failure")
    } catch {
        XCTAssertEqual(error as? PresetStoreFailure, expected)
    }
}

private func assertPromptFailure(
    _ expected: PromptPresetFailure,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected prompt preset failure")
    } catch {
        XCTAssertEqual(error as? PromptPresetFailure, expected)
    }
}

private extension CustomPreset {
    static let privateFixture = CustomPreset(
        id: PresetID(rawValue: "custom-11111111-1111-1111-1111-111111111111"),
        name: "Private Name Z8q",
        explanation: "Private Explanation Y7p",
        template: "Private Template X6o {text}",
        targetLanguage: .identified("zh-Hans"),
        action: .translate
    )

    static let secondFixture = CustomPreset(
        id: PresetID(rawValue: "custom-22222222-2222-2222-2222-222222222222"),
        name: "Second Name Q5n",
        explanation: "Second Explanation P4m",
        template: "Second Template O3l {text}",
        targetLanguage: .automatic,
        action: .polish
    )

    static func numbered(_ value: Int) -> CustomPreset {
        CustomPreset(
            id: PresetID(rawValue: String(format: "custom-00000000-0000-0000-0000-%012d", value)),
            name: "Name \(value)",
            explanation: "Explanation \(value)",
            template: "Template \(value) {text}",
            targetLanguage: .automatic,
            action: .translate
        )
    }

    var plaintextFields: [String] { [name, explanation, template] }

    func replacingID(_ id: PresetID) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }

    func replacingName(_ name: String) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }

    func replacingExplanation(_ explanation: String) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }

    func replacingTemplate(_ template: String) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }
}
