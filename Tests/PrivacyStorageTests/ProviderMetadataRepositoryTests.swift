import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class ProviderMetadataRepositoryTests: XCTestCase {
    func testFirstWriteReplacementReopenAndModes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let repository = ProviderMetadataRepository(fileURL: file)

        var envelope = ProviderMetadataEnvelope.empty
        envelope.records = [syntheticRecord(model: "one")]
        try await repository.install(envelope)
        var reopened = try await repository.load()
        XCTAssertEqual(fileMode(file), 0o600)
        XCTAssertEqual(reopened.records.only?.model, "one")

        envelope.records[0].model = "two"
        try await repository.install(envelope)
        reopened = try await repository.load()
        XCTAssertEqual(fileMode(file), 0o600)
        XCTAssertEqual(reopened.records.only?.model, "two")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, ["providers.plist"])
    }

    func testSymlinkDestinationRejectedWithoutChangingTarget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let destination = directory.appendingPathComponent("providers.plist")
        try Data("prior".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: target.path
        )
        let repository = ProviderMetadataRepository(fileURL: destination)
        do {
            try await repository.install(.empty)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("prior".utf8))
    }

    func testDecodeFailurePreservesOriginalBytes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let invalid = Data("not-a-property-list".utf8)
        try invalid.write(to: file)
        let repository = ProviderMetadataRepository(fileURL: file)
        do {
            _ = try await repository.load()
            XCTFail("Expected decode rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testReopenRejectsSymlinkDirectoryAndDuplicateRecordIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("valid.plist")
        let symlink = directory.appendingPathComponent("linked.plist")
        try PropertyListEncoder().encode(ProviderMetadataEnvelope.empty).write(to: valid)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: valid.path
        )
        do {
            _ = try await ProviderMetadataRepository(fileURL: symlink).load()
            XCTFail("Expected no-follow read rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        do {
            _ = try await ProviderMetadataRepository(fileURL: directory).load()
            XCTFail("Expected nonregular read rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }

        let duplicateID = ProviderConfigurationID()
        let duplicate = ProviderMetadataEnvelope(
            version: 1,
            records: [
                syntheticRecord(id: duplicateID, model: "one"),
                syntheticRecord(id: duplicateID, model: "two")
            ],
            offDeviceAuthorizations: [duplicateID: []]
        )
        let duplicateFile = directory.appendingPathComponent("duplicate.plist")
        try PropertyListEncoder().encode(duplicate).write(to: duplicateFile)
        do {
            _ = try await ProviderMetadataRepository(fileURL: duplicateFile).load()
            XCTFail("Expected duplicate record rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
    }

    func testFileAndDirectorySyncFailuresPreserveDefinedAuthority() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")

        let fileSyncRepository = ProviderMetadataRepository(
            fileURL: file,
            installer: SameDirectoryAtomicInstaller(
                hooks: AtomicInstallerHooks(failFileSync: true)
            )
        )
        do {
            try await fileSyncRepository.install(.empty)
            XCTFail("Expected file fsync failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let directorySyncRepository = ProviderMetadataRepository(
            fileURL: file,
            installer: SameDirectoryAtomicInstaller(
                hooks: AtomicInstallerHooks(failDirectorySync: true)
            )
        )
        do {
            try await directorySyncRepository.install(.empty)
            XCTFail("Expected durability uncertainty")
        } catch ProviderMetadataPersistenceFailure.durabilityUncertain(
            let authoritative
        ) {
            XCTAssertEqual(authoritative.version, 1)
        }
        let reopened = try await directorySyncRepository.load()
        XCTAssertEqual(reopened.version, 1)
    }

    func testDurabilityUncertaintyWhoseReloadFailsRemainsTyped() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let repository = ProviderMetadataRepository(
            fileURL: file,
            installer: SymlinkThenUncertainInstaller()
        )
        do {
            try await repository.install(.empty)
            XCTFail("Expected typed reload failure")
        } catch ProviderMetadataPersistenceFailure.durabilityUncertainReloadFailed {
            // The uncertainty category must survive even when authority is unreadable.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExistingReplacementRaceDoesNotOverwriteRacer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let prior = try PropertyListEncoder().encode(ProviderMetadataEnvelope.empty)
        try prior.write(to: file)
        let racer = Data("racer".utf8)
        let installer = SameDirectoryAtomicInstaller(hooks: AtomicInstallerHooks(
            beforeExistingSwap: { destination in
                try FileManager.default.removeItem(at: destination)
                try racer.write(to: destination)
            }
        ))
        XCTAssertThrowsError(try installer.install(prior, at: file))
        XCTAssertEqual(try Data(contentsOf: file), racer)
    }

    func testRollbackSwapAndSyncFailuresPreserveRacerOrReportUncertainty() throws {
        for failSwap in [true, false] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("providers.plist")
            let valid = try PropertyListEncoder().encode(ProviderMetadataEnvelope.empty)
            try valid.write(to: file)
            let racer = Data("racer-\(failSwap)".utf8)
            let installer = SameDirectoryAtomicInstaller(hooks: AtomicInstallerHooks(
                beforeExistingSwap: { destination in
                    try FileManager.default.removeItem(at: destination)
                    try racer.write(to: destination)
                },
                failRollbackSwap: failSwap,
                failRollbackSync: !failSwap
            ))
            XCTAssertThrowsError(try installer.install(valid, at: file)) { error in
                XCTAssertEqual(error as? AtomicInstallFailure, .durabilityUncertain)
            }
            if !failSwap {
                XCTAssertEqual(try Data(contentsOf: file), racer)
            } else {
                let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                XCTAssertEqual(entries.count, 2)
                XCTAssertTrue(entries.contains { name in
                    let data = try? Data(contentsOf: directory.appendingPathComponent(name))
                    return data == racer
                })
            }
        }
    }

    func testLegacyVersionOneAndDuplicateAuthorizationHandling() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let id = ProviderConfigurationID()
        let legacyRecord = LegacyProviderRecord(
            id: id,
            protocolKind: .ollamaNative,
            endpoint: URL(string: "http://127.0.0.1:11434")!,
            model: "",
            confirmedClass: nil,
            configurationRevision: 1,
            confirmationRevision: 0,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active,
            pendingUpdate: nil
        )
        let legacy = LegacyEnvelope(
            version: 1,
            records: [legacyRecord],
            offDeviceAuthorizations: [LegacyAuthorizationEntry(id: id, applications: [])]
        )
        try PropertyListEncoder().encode(legacy).write(to: file)
        let loaded = try await ProviderMetadataRepository(fileURL: file).load()
        XCTAssertEqual(loaded.records.only?.role, .userDefined)

        let duplicates = LegacyEnvelope(
            version: 1,
            records: [legacyRecord],
            offDeviceAuthorizations: [
                LegacyAuthorizationEntry(id: id, applications: []),
                LegacyAuthorizationEntry(id: id, applications: [])
            ]
        )
        try PropertyListEncoder().encode(duplicates).write(to: file)
        do {
            _ = try await ProviderMetadataRepository(fileURL: file).load()
            XCTFail("Expected duplicate authorization rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
    }

    func testActionAndCredentialOwnershipInvariantsRejectMalformedEnvelope() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.plist")
        let shared = UUID()
        var first = syntheticRecord(model: "one")
        var second = syntheticRecord(model: "two")
        first.activeCredentialAccount = shared
        second.activeCredentialAccount = shared
        let duplicateOwner = ProviderMetadataEnvelope(
            version: 1,
            records: [first, second],
            offDeviceAuthorizations: [first.id: [], second.id: []]
        )
        try PropertyListEncoder().encode(duplicateOwner).write(to: file)
        do {
            _ = try await ProviderMetadataRepository(fileURL: file).load()
            XCTFail("Expected shared account rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }

        var malformed = syntheticRecord(model: "bad")
        malformed.state = .recoveryRequired
        malformed.recoveryAction = .restoreActiveAfterCredentialCleanup
        malformed.pendingUpdate = nil
        let badAction = ProviderMetadataEnvelope(
            version: 1,
            records: [malformed],
            offDeviceAuthorizations: [malformed.id: []]
        )
        try PropertyListEncoder().encode(badAction).write(to: file)
        do {
            _ = try await ProviderMetadataRepository(fileURL: file).load()
            XCTFail("Expected action invariant rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlideTranslate-P5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func fileMode(_ url: URL) -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return 0 }
    return value.st_mode & mode_t(0o777)
}

private func syntheticRecord(
    id: ProviderConfigurationID = ProviderConfigurationID(),
    model: String
) -> ProviderConfigurationRecord {
    ProviderConfigurationRecord(
        id: id,
        protocolKind: .openAICompatible,
        endpoint: URL(string: "https://example.invalid/v1")!,
        model: model,
        confirmedClass: .cloud,
        configurationRevision: 1,
        confirmationRevision: 1,
        activeCredentialAccount: nil,
        pendingCredentialAccount: nil,
        cleanupCredentialAccounts: [],
        state: .active
    )
}

private struct SymlinkThenUncertainInstaller: AtomicDataInstalling {
    func install(_ data: Data, at destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: destination
                .deletingLastPathComponent()
                .appendingPathComponent("missing-authority")
                .path
        )
        throw AtomicInstallFailure.durabilityUncertain
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private struct LegacyProviderRecord: Codable {
    let id: ProviderConfigurationID
    let protocolKind: ProviderProtocolKind
    let endpoint: URL
    let model: String
    let confirmedClass: DestinationPrivacyClass?
    let configurationRevision: UInt64
    let confirmationRevision: UInt64
    let activeCredentialAccount: UUID?
    let pendingCredentialAccount: UUID?
    let cleanupCredentialAccounts: [UUID]
    let state: ProviderRecordState
    let pendingUpdate: ProviderPendingUpdate?
}

private struct LegacyAuthorizationEntry: Codable {
    let id: ProviderConfigurationID
    let applications: Set<ApplicationIdentity>
}

private struct LegacyEnvelope: Codable {
    let version: UInt16
    let records: [LegacyProviderRecord]
    let offDeviceAuthorizations: [LegacyAuthorizationEntry]
}
