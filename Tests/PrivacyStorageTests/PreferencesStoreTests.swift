import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class PreferencesStoreTests: XCTestCase {
    func testDefaultsAreExactAndProviderAuthorizationStartsEmpty() async throws {
        let fixture = try PreferencesFixture.empty()
        defer { fixture.remove() }

        let snapshot = try await fixture.store.snapshot()

        XCTAssertEqual(snapshot.uiLanguage, ApplicationLanguage.english)
        XCTAssertEqual(snapshot.defaultTargetLanguage, LanguageChoice.automatic)
        XCTAssertFalse(snapshot.onboardingCompleted)
        XCTAssertFalse(snapshot.automaticCaptureEnabled)
        XCTAssertEqual(snapshot.generalAutomaticApplications, Set<ApplicationIdentity>())
        XCTAssertFalse(snapshot.mouseSelectionEnabled)
        XCTAssertFalse(snapshot.keyboardSelectionEnabled)
        XCTAssertFalse(snapshot.clipboardFallbackEnabled)
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertEqual(snapshot.historyRetentionDays, 30)
        XCTAssertEqual(snapshot.historyMaximumCount, 1_000)
        XCTAssertEqual(snapshot.selectionDebounceMilliseconds, 350)
        XCTAssertEqual(snapshot.selectionCharacterLimit, 2_000)
        XCTAssertEqual(snapshot.connectionTimeoutSeconds, 5)
        XCTAssertEqual(snapshot.firstTokenTimeoutSeconds, 120)
        XCTAssertEqual(snapshot.streamIdleTimeoutSeconds, 30)
        XCTAssertFalse(snapshot.launchAtLogin)
        XCTAssertEqual(snapshot.shortcut, ShortcutDescriptor.defaultOptionShiftD)
        XCTAssertEqual(snapshot.defaultPresetID.rawValue, "accurate-translation")
        XCTAssertNil(snapshot.defaultProviderID)
        XCTAssertEqual(snapshot.historyExcludedApplications, Set<ApplicationIdentity>())
    }

    func testFirstWriteAndExistingReplacementReopenWithMode0600() async throws {
        let fixture = try PreferencesFixture.empty()
        defer { fixture.remove() }

        try await fixture.store.update { $0.selectionCharacterLimit = 500 }
        var reopened = try await fixture.reopen().snapshot()
        XCTAssertEqual(reopened.selectionCharacterLimit, 500)
        XCTAssertEqual(preferencesFileMode(fixture.fileURL), 0o600)

        try await fixture.store.update { $0.selectionCharacterLimit = 700 }
        reopened = try await fixture.reopen().snapshot()
        XCTAssertEqual(reopened.selectionCharacterLimit, 700)
        XCTAssertEqual(preferencesFileMode(fixture.fileURL), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path),
            ["preferences.plist"]
        )
    }

    func testFailedReplacementPreservesPreviousDiskAndMemorySnapshot() async throws {
        let installer = FailOnInstallNumber(2)
        let fixture = try PreferencesFixture.empty(installer: installer)
        defer { fixture.remove() }

        try await fixture.store.update { $0.selectionCharacterLimit = 500 }
        let previousBytes = try Data(contentsOf: fixture.fileURL)

        do {
            try await fixture.store.update { $0.selectionCharacterLimit = 700 }
            XCTFail("Expected replacement failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), previousBytes)
        let memoryLimit = try await fixture.store.snapshot().selectionCharacterLimit
        let diskLimit = try await fixture.reopen().snapshot().selectionCharacterLimit
        XCTAssertEqual(memoryLimit, 500)
        XCTAssertEqual(diskLimit, 500)
    }

    func testFailedFirstWriteLeavesDestinationAbsentAndDefaultsReadable() async throws {
        let fixture = try PreferencesFixture.empty(installer: FailOnInstallNumber(1))
        defer { fixture.remove() }

        do {
            try await fixture.store.update { $0.historyEnabled = true }
            XCTFail("Expected first-write failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let snapshot = try await fixture.store.snapshot()
        XCTAssertFalse(snapshot.historyEnabled)
    }

    func testDirectorySyncUncertaintyReloadsInstalledAuthorityBeforeReportingFailure() async throws {
        let fixture = try PreferencesFixture.empty(
            installer: SameDirectoryAtomicInstaller(
                hooks: AtomicInstallerHooks(failDirectorySync: true)
            )
        )
        defer { fixture.remove() }

        do {
            try await fixture.store.update { $0.historyEnabled = true }
            XCTFail("Expected durability uncertainty")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }

        let memory = try await fixture.store.snapshot()
        let disk = try await fixture.reopen().snapshot()
        XCTAssertTrue(memory.historyEnabled)
        XCTAssertTrue(disk.historyEnabled)
    }

    func testDurabilityUncertainAuthoritativeShrinkStillAttemptsProviderCleanup() async throws {
        let appA = syntheticApplication("a")
        let appB = syntheticApplication("b")
        let maintenance = InspectingMaintenance()
        let fixture = try PreferencesFixture.empty(
            installer: DirectorySyncUncertainOnInstallNumber(2),
            reconcileOffDeviceAuthorizations: { _ in try await maintenance.run() }
        )
        defer { fixture.remove() }
        await maintenance.configure(fileURL: fixture.fileURL, failure: false)
        try await fixture.store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }

        do {
            try await fixture.store.update {
                $0.generalAutomaticApplications = [appA]
            }
            XCTFail("Expected durability uncertainty")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }

        let maintenanceCalls = await maintenance.calls()
        let observed = await maintenance.observedApplications()
        let memory = try await fixture.store.snapshot().generalAutomaticApplications
        let disk = try await fixture.reopen().snapshot().generalAutomaticApplications
        XCTAssertEqual(maintenanceCalls, 1)
        XCTAssertEqual(observed, [appA])
        XCTAssertEqual(memory, [appA])
        XCTAssertEqual(disk, [appA])
    }

    func testEncodedPreferencesContainNoContentCredentialOrProviderAuthorizationFields() async throws {
        let fixture = try PreferencesFixture.empty()
        defer { fixture.remove() }
        try await fixture.store.update { $0.historyEnabled = true }

        let keys = try recursivePropertyListKeys(at: fixture.fileURL)
        XCTAssertTrue(keys.isDisjoint(with: [
            "selectedText", "translation", "credential", "endpoint",
            "privatePrompt", "windowTitle", "modelPath", "offDeviceAuthorizations"
        ]))
    }

    func testUnknownVersionAndMalformedFileAreUnrecoverableWithoutReset() async throws {
        for bytes in [try unknownVersionBytes(), Data("not-a-property-list".utf8)] {
            let fixture = try PreferencesFixture.containing(bytes)
            defer { fixture.remove() }

            do {
                _ = try await fixture.openExisting()
                XCTFail("Expected unrecoverable preferences")
            } catch {
                XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
        }
    }

    func testSymlinkAndDirectoryDestinationsAreRejectedWithoutChangingTheirTargets() async throws {
        let directoryFixture = try PreferencesFixture.destinationIsDirectory()
        defer { directoryFixture.remove() }
        do {
            try await directoryFixture.store.update { $0.historyEnabled = true }
            XCTFail("Expected directory rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directoryFixture.fileURL.path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)

        let symlinkFixture = try PreferencesFixture.destinationIsSymlink()
        defer { symlinkFixture.remove() }
        do {
            try await symlinkFixture.store.update { $0.historyEnabled = true }
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }
        XCTAssertEqual(try Data(contentsOf: symlinkFixture.symlinkTarget!), Data("prior".utf8))
    }

    func testEveryNumericBoundaryIsInclusiveAndOutOfRangeLeavesDiskAndMemoryUnchanged() async throws {
        let accepted: [NumericPreferenceRow] = [
            .init({ $0.selectionDebounceMilliseconds = 100 }, { $0.selectionDebounceMilliseconds }, 100),
            .init({ $0.selectionDebounceMilliseconds = 2_000 }, { $0.selectionDebounceMilliseconds }, 2_000),
            .init({ $0.selectionCharacterLimit = 1 }, { $0.selectionCharacterLimit }, 1),
            .init({ $0.selectionCharacterLimit = 20_000 }, { $0.selectionCharacterLimit }, 20_000),
            .init({ $0.historyRetentionDays = 1 }, { $0.historyRetentionDays }, 1),
            .init({ $0.historyRetentionDays = 365 }, { $0.historyRetentionDays }, 365),
            .init({ $0.historyMaximumCount = 1 }, { $0.historyMaximumCount }, 1),
            .init({ $0.historyMaximumCount = 10_000 }, { $0.historyMaximumCount }, 10_000),
            .init({ $0.connectionTimeoutSeconds = 1 }, { $0.connectionTimeoutSeconds }, 1),
            .init({ $0.connectionTimeoutSeconds = 60 }, { $0.connectionTimeoutSeconds }, 60),
            .init({ $0.firstTokenTimeoutSeconds = 5 }, { $0.firstTokenTimeoutSeconds }, 5),
            .init({ $0.firstTokenTimeoutSeconds = 600 }, { $0.firstTokenTimeoutSeconds }, 600),
            .init({ $0.streamIdleTimeoutSeconds = 5 }, { $0.streamIdleTimeoutSeconds }, 5),
            .init({ $0.streamIdleTimeoutSeconds = 120 }, { $0.streamIdleTimeoutSeconds }, 120)
        ]
        for (index, row) in accepted.enumerated() {
            let fixture = try PreferencesFixture.named("accepted-\(index)")
            defer { fixture.remove() }
            try await fixture.store.update(row.mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
            let reopened = try await fixture.reopen().snapshot()
            XCTAssertEqual(row.value(reopened), row.expected)
        }

        let rejected: [@Sendable (inout PreferencesSnapshot) -> Void] = [
            { $0.selectionDebounceMilliseconds = 99 },
            { $0.selectionDebounceMilliseconds = 2_001 },
            { $0.selectionCharacterLimit = 0 },
            { $0.selectionCharacterLimit = 20_001 },
            { $0.historyRetentionDays = 0 },
            { $0.historyRetentionDays = 366 },
            { $0.historyMaximumCount = 0 },
            { $0.historyMaximumCount = 10_001 },
            { $0.connectionTimeoutSeconds = 0 },
            { $0.connectionTimeoutSeconds = 61 },
            { $0.firstTokenTimeoutSeconds = 4 },
            { $0.firstTokenTimeoutSeconds = 601 },
            { $0.streamIdleTimeoutSeconds = 4 },
            { $0.streamIdleTimeoutSeconds = 121 }
        ]
        for (index, mutation) in rejected.enumerated() {
            let fixture = try PreferencesFixture.named("rejected-\(index)")
            defer { fixture.remove() }
            do {
                try await fixture.store.update(mutation)
                XCTFail("Expected validation rejection for row \(index)")
            } catch {
                XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
            let snapshot = try await fixture.store.snapshot()
            XCTAssertEqual(snapshot.selectionDebounceMilliseconds, 350)
            XCTAssertEqual(snapshot.selectionCharacterLimit, 2_000)
            XCTAssertEqual(snapshot.historyRetentionDays, 30)
            XCTAssertEqual(snapshot.historyMaximumCount, 1_000)
            XCTAssertEqual(snapshot.connectionTimeoutSeconds, 5)
            XCTAssertEqual(snapshot.firstTokenTimeoutSeconds, 120)
            XCTAssertEqual(snapshot.streamIdleTimeoutSeconds, 30)
        }
    }

    func testThrowingTransformHasNoDiskOrMemoryEffect() async throws {
        let fixture = try PreferencesFixture.empty()
        defer { fixture.remove() }

        do {
            try await fixture.store.update {
                $0.historyEnabled = true
                throw SyntheticPreferencesFailure.transformFailed
            }
            XCTFail("Expected transform failure")
        } catch {
            XCTAssertEqual(error as? SyntheticPreferencesFailure, .transformFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let historyEnabled = try await fixture.store.snapshot().historyEnabled
        XCTAssertFalse(historyEnabled)
    }

    func testGeneralAllowlistShrinkCommitsBeforeCleanupAndCleanupFailureDoesNotRollback() async throws {
        let appA = syntheticApplication("a")
        let appB = syntheticApplication("b")
        let maintenance = InspectingMaintenance()
        let fixture = try PreferencesFixture.empty(
            reconcileOffDeviceAuthorizations: { _ in try await maintenance.run() }
        )
        defer { fixture.remove() }
        await maintenance.configure(fileURL: fixture.fileURL, failure: true)

        try await fixture.store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }
        do {
            try await fixture.store.update {
                $0.generalAutomaticApplications = [appA]
            }
            XCTFail("Expected best-effort cleanup failure")
        } catch {
            XCTAssertEqual(error as? ProviderAuthorizationFailure, .maintenanceFailed)
        }

        let maintenanceCalls = await maintenance.calls()
        let observedApplications = await maintenance.observedApplications()
        let memoryApplications = try await fixture.store.snapshot()
            .generalAutomaticApplications
        let diskApplications = try await fixture.reopen().snapshot()
            .generalAutomaticApplications
        XCTAssertEqual(maintenanceCalls, 1)
        XCTAssertEqual(observedApplications, [appA])
        XCTAssertEqual(memoryApplications, [appA])
        XCTAssertEqual(diskApplications, [appA])
    }

    func testConcurrentShrinksCannotRestoreAStaleBroaderSnapshot() async throws {
        let appA = syntheticApplication("a")
        let appB = syntheticApplication("b")
        let maintenance = BlockingFirstMaintenance()
        let fixture = try PreferencesFixture.empty(
            reconcileOffDeviceAuthorizations: { _ in await maintenance.run() }
        )
        defer { fixture.remove() }
        try await fixture.store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }

        let first = Task {
            try await fixture.store.update {
                $0.generalAutomaticApplications = [appA]
            }
        }
        while !(await maintenance.firstCallIsBlocked()) { await Task.yield() }
        let second = Task {
            try await fixture.store.update {
                $0.generalAutomaticApplications = []
            }
        }
        try await second.value
        await maintenance.releaseFirst()
        try await first.value

        let maintenanceCalls = await maintenance.callCount()
        let memoryApplications = try await fixture.store.snapshot()
            .generalAutomaticApplications
        let diskApplications = try await fixture.reopen().snapshot()
            .generalAutomaticApplications
        XCTAssertEqual(maintenanceCalls, 2)
        XCTAssertEqual(memoryApplications, Set<ApplicationIdentity>())
        XCTAssertEqual(diskApplications, Set<ApplicationIdentity>())
    }

    func testDelayedShrinkCleanupUsesCommittedCeilingDespiteLaterExpansion() async throws {
        let appA = syntheticApplication("a")
        let appB = syntheticApplication("b")
        let maintenance = BlockingRealVaultMaintenance()
        let fixture = try PreferencesFixture.empty(
            reconcileOffDeviceAuthorizations: {
                try await maintenance.run(ceiling: $0)
            }
        )
        defer { fixture.remove() }
        let vault = try await DefaultProviderVault.open(
            metadata: MemoryProviderMetadata(),
            credentials: MemoryCredentialStore(),
            generalApplications: fixture.store
        )
        await maintenance.bind(vault)
        try await fixture.store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }
        let provider = try await vault.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "model"
            ),
            credential: nil
        )
        _ = try await vault.commitConfirmation(
            id: provider.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await vault.setAutomaticApplications([appA, appB], for: provider.id)

        await maintenance.blockNextRun()
        let shrink = Task {
            try await fixture.store.update {
                $0.generalAutomaticApplications = [appA]
            }
        }
        while !(await maintenance.isBlocked()) { await Task.yield() }
        try await fixture.store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }
        await maintenance.release()
        try await shrink.value

        let persisted = try await vault.automaticApplications(for: provider.id)
        XCTAssertEqual(persisted, [appA])
    }

    func testGeneralAllowlistExpansionDoesNotRunProviderCleanup() async throws {
        let maintenance = InspectingMaintenance()
        let fixture = try PreferencesFixture.empty(
            reconcileOffDeviceAuthorizations: { _ in try await maintenance.run() }
        )
        defer { fixture.remove() }
        await maintenance.configure(fileURL: fixture.fileURL, failure: false)

        try await fixture.store.update {
            $0.generalAutomaticApplications = [syntheticApplication("a")]
        }

        let maintenanceCalls = await maintenance.calls()
        XCTAssertEqual(maintenanceCalls, 0)
    }

    func testOneTimeWeakBridgeComposesRealPreferencesAndProviderVault() async throws {
        let appA = syntheticApplication("a")
        let appB = syntheticApplication("b")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideTranslate-T7-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = ProviderAuthorizationReconciliationBridge()
        let store = try AtomicPreferencesStore.open(
            fileURL: directory.appendingPathComponent("preferences.plist"),
            installer: SameDirectoryAtomicInstaller(),
            offDeviceAuthorizationReconciler: bridge
        )
        let metadata = MemoryProviderMetadata()
        let vault = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: MemoryCredentialStore(),
            generalApplications: store
        )
        let initialProviderPolicy = await metadata.snapshot().offDeviceAuthorizations
        XCTAssertEqual(initialProviderPolicy, [:])
        try await bridge.bind(vault)
        do {
            try await bridge.bind(vault)
            XCTFail("Expected one-time binding rejection")
        } catch {
            XCTAssertEqual(error as? ProviderAuthorizationFailure, .maintenanceFailed)
        }

        try await store.update {
            $0.generalAutomaticApplications = [appA, appB]
        }
        let provider = try await vault.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "model"
            ),
            credential: nil
        )
        _ = try await vault.commitConfirmation(
            id: provider.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await vault.setAutomaticApplications([appA, appB], for: provider.id)

        try await store.update {
            $0.generalAutomaticApplications = [appA]
        }

        let readable = try await vault.automaticApplications(for: provider.id)
        let persisted = await metadata.snapshot().offDeviceAuthorizations[provider.id]
        XCTAssertEqual(readable, [appA])
        XCTAssertEqual(persisted, [appA])
    }

    func testUnboundBridgeReportsMaintenanceFailureAfterPersistingNarrowerPolicy() async throws {
        let appA = syntheticApplication("a")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideTranslate-T7-unbound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("preferences.plist")
        let bridge = ProviderAuthorizationReconciliationBridge()
        let store = try AtomicPreferencesStore.open(
            fileURL: fileURL,
            offDeviceAuthorizationReconciler: bridge
        )
        try await store.update { $0.generalAutomaticApplications = [appA] }

        do {
            try await store.update { $0.generalAutomaticApplications = [] }
            XCTFail("Expected unbound maintenance failure")
        } catch {
            XCTAssertEqual(error as? ProviderAuthorizationFailure, .maintenanceFailed)
        }

        let memory = try await store.snapshot().generalAutomaticApplications
        let reopened = try AtomicPreferencesStore.open(
            fileURL: fileURL,
            offDeviceAuthorizationReconciler: bridge
        )
        let disk = try await reopened.snapshot().generalAutomaticApplications
        XCTAssertEqual(memory, [])
        XCTAssertEqual(disk, [])
    }

    func testBridgeDoesNotKeepBoundVaultAlive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideTranslate-T7-weak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = ProviderAuthorizationReconciliationBridge()
        let store = try AtomicPreferencesStore.open(
            fileURL: directory.appendingPathComponent("preferences.plist"),
            offDeviceAuthorizationReconciler: bridge
        )
        var vault: DefaultProviderVault? = try await DefaultProviderVault.open(
            metadata: MemoryProviderMetadata(),
            credentials: MemoryCredentialStore(),
            generalApplications: store
        )
        weak let weakVault = vault
        try await bridge.bind(vault!)

        vault = nil

        XCTAssertNil(weakVault)
    }
}

private struct PreferencesFixture {
    let directory: URL
    let fileURL: URL
    let store: AtomicPreferencesStore
    let installer: any AtomicDataInstalling
    let reconcileOffDeviceAuthorizations:
        @Sendable (Set<ApplicationIdentity>) async throws -> Void
    let symlinkTarget: URL?

    static func empty(
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        reconcileOffDeviceAuthorizations: @escaping @Sendable (
            Set<ApplicationIdentity>
        ) async throws -> Void = { _ in }
    ) throws -> Self {
        try named(
            UUID().uuidString,
            installer: installer,
            reconcileOffDeviceAuthorizations: reconcileOffDeviceAuthorizations
        )
    }

    static func named(
        _ name: String,
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        reconcileOffDeviceAuthorizations: @escaping @Sendable (
            Set<ApplicationIdentity>
        ) async throws -> Void = { _ in }
    ) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideTranslate-T7-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = directory.appendingPathComponent("preferences.plist")
        return Self(
            directory: directory,
            fileURL: fileURL,
            store: try AtomicPreferencesStore.open(
                fileURL: fileURL,
                installer: installer,
                offDeviceAuthorizationReconciler:
                    ClosureOffDeviceAuthorizationReconciler(
                        body: reconcileOffDeviceAuthorizations
                    )
            ),
            installer: installer,
            reconcileOffDeviceAuthorizations: reconcileOffDeviceAuthorizations,
            symlinkTarget: nil
        )
    }

    static func containing(_ data: Data) throws -> Self {
        let fixture = try named(UUID().uuidString)
        try data.write(to: fixture.fileURL)
        return fixture
    }

    static func destinationIsDirectory() throws -> Self {
        let fixture = try named(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)
        return fixture
    }

    static func destinationIsSymlink() throws -> Self {
        let fixture = try named(UUID().uuidString)
        let target = fixture.directory.appendingPathComponent("target")
        try Data("prior".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.fileURL.path,
            withDestinationPath: target.path
        )
        return Self(
            directory: fixture.directory,
            fileURL: fixture.fileURL,
            store: fixture.store,
            installer: fixture.installer,
            reconcileOffDeviceAuthorizations: fixture.reconcileOffDeviceAuthorizations,
            symlinkTarget: target
        )
    }

    func openExisting() async throws -> AtomicPreferencesStore {
        try AtomicPreferencesStore.open(
            fileURL: fileURL,
            installer: installer,
            offDeviceAuthorizationReconciler:
                ClosureOffDeviceAuthorizationReconciler(
                    body: reconcileOffDeviceAuthorizations
                )
        )
    }

    func reopen() async throws -> AtomicPreferencesStore {
        try await openExisting()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class FailOnInstallNumber: AtomicDataInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let failureNumber: Int
    private var callCount = 0

    init(_ failureNumber: Int) {
        self.failureNumber = failureNumber
    }

    func install(_ data: Data, at destination: URL) throws {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failureNumber
        lock.unlock()
        if shouldFail { throw AtomicInstallFailure.writeFailed }
        try SameDirectoryAtomicInstaller().install(data, at: destination)
    }
}

private struct ClosureOffDeviceAuthorizationReconciler:
    OffDeviceAuthorizationReconciling {
    let body: @Sendable (Set<ApplicationIdentity>) async throws -> Void

    func reconcileOffDeviceAuthorizations(
        withGeneralAllowlistCeiling ceiling: Set<ApplicationIdentity>
    ) async throws {
        try await body(ceiling)
    }
}

private final class DirectorySyncUncertainOnInstallNumber:
    AtomicDataInstalling,
    @unchecked Sendable {
    private let lock = NSLock()
    private let uncertaintyNumber: Int
    private var callCount = 0

    init(_ uncertaintyNumber: Int) {
        self.uncertaintyNumber = uncertaintyNumber
    }

    func install(_ data: Data, at destination: URL) throws {
        lock.lock()
        callCount += 1
        let shouldBeUncertain = callCount == uncertaintyNumber
        lock.unlock()
        let hooks = AtomicInstallerHooks(failDirectorySync: shouldBeUncertain)
        try SameDirectoryAtomicInstaller(hooks: hooks).install(data, at: destination)
    }
}

private actor InspectingMaintenance {
    private var fileURL: URL?
    private var shouldFail = false
    private var callCount = 0
    private var observed: Set<ApplicationIdentity> = []

    func configure(fileURL: URL, failure: Bool) {
        self.fileURL = fileURL
        shouldFail = failure
    }

    func run() throws {
        callCount += 1
        if let fileURL {
            let data = try Data(contentsOf: fileURL)
            let envelope = try PropertyListDecoder().decode(
                DecodedPreferencesEnvelope.self,
                from: data
            )
            observed = envelope.snapshot.generalAutomaticApplications
        }
        if shouldFail { throw SyntheticPreferencesFailure.maintenanceFailed }
    }

    func calls() -> Int { callCount }
    func observedApplications() -> Set<ApplicationIdentity> { observed }
}

private actor BlockingFirstMaintenance {
    private var calls = 0
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        calls += 1
        guard calls == 1 else { return }
        blocked = true
        await withCheckedContinuation { continuation = $0 }
        blocked = false
    }

    func firstCallIsBlocked() -> Bool { blocked }
    func callCount() -> Int { calls }
    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingRealVaultMaintenance {
    private var vault: DefaultProviderVault?
    private var shouldBlock = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func bind(_ vault: DefaultProviderVault) {
        self.vault = vault
    }

    func blockNextRun() { shouldBlock = true }
    func isBlocked() -> Bool { blocked }
    func release() {
        continuation?.resume()
        continuation = nil
    }

    func run(ceiling: Set<ApplicationIdentity>) async throws {
        if shouldBlock {
            shouldBlock = false
            blocked = true
            await withCheckedContinuation { continuation = $0 }
            blocked = false
        }
        guard let vault else {
            throw SyntheticPreferencesFailure.maintenanceFailed
        }
        try await vault.reconcileAutomaticApplications(
            withGeneralAllowlistCeiling: ceiling
        )
    }
}

private enum SyntheticPreferencesFailure: Error, Equatable {
    case transformFailed
    case maintenanceFailed
}

private struct DecodedPreferencesEnvelope: Decodable {
    let version: UInt16
    let snapshot: PreferencesSnapshot
}

private struct NumericPreferenceRow: Sendable {
    let mutation: @Sendable (inout PreferencesSnapshot) -> Void
    let value: @Sendable (PreferencesSnapshot) -> Int
    let expected: Int

    init(
        _ mutation: @escaping @Sendable (inout PreferencesSnapshot) -> Void,
        _ value: @escaping @Sendable (PreferencesSnapshot) -> Int,
        _ expected: Int
    ) {
        self.mutation = mutation
        self.value = value
        self.expected = expected
    }
}

private func syntheticApplication(_ suffix: String) -> ApplicationIdentity {
    ApplicationIdentity(
        bundleIdentifier: "invalid.example.\(suffix)",
        displayName: suffix.uppercased()
    )
}

private func preferencesFileMode(_ url: URL) -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return 0 }
    return value.st_mode & mode_t(0o777)
}

private func recursivePropertyListKeys(at url: URL) throws -> Set<String> {
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url),
        format: nil
    )
    func collect(_ value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return Set(dictionary.keys).union(dictionary.values.flatMap(collect))
        }
        if let array = value as? [Any] {
            return Set(array.flatMap(collect))
        }
        return []
    }
    return collect(plist)
}

private func unknownVersionBytes() throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(UnknownPreferencesEnvelope(
        version: 2,
        snapshot: .defaultValue
    ))
}

private struct UnknownPreferencesEnvelope: Encodable {
    let version: UInt16
    let snapshot: PreferencesSnapshot
}
