import Darwin
import Foundation
import SharedSupport
import XCTest
@testable import PrivacyStorage

final class PrivacyStorageFactoryTests: XCTestCase {
    func testCorruptPreferencesStillPublishesResetAndReopensDefaults() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        try fixture.prepareRoot()
        try Data("malformed-preferences".utf8).write(
            to: fixture.root.appendingPathComponent("preferences.plist")
        )

        let degraded = try await fixture.makeServices()
        do {
            _ = try await degraded.preferences.snapshot()
            XCTFail("corrupt preferences must remain unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .preferencesUnrecoverable)
        }
        try await degraded.reset.resetPreferences()

        let reopened = try await fixture.makeServices()
        let snapshot = try await reopened.preferences.snapshot()
        XCTAssertFalse(snapshot.automaticCaptureEnabled)
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertTrue(snapshot.generalAutomaticApplications.isEmpty)
    }

    func testCorruptPresetAuthorityStillPublishesResetWithoutRegeneratingKey() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        try fixture.prepareRoot()
        fixture.keys.seed(
            service: "com.example.GlideTranslate.private-presets-key",
            account: "v1",
            data: Data(repeating: 7, count: 32)
        )
        try Data("malformed-presets".utf8).write(
            to: fixture.root.appendingPathComponent("private-presets.plist")
        )

        let degraded = try await fixture.makeServices()
        do {
            _ = try await degraded.customPresets.customPresets()
            XCTFail("corrupt presets must remain unavailable")
        } catch {
            XCTAssertEqual(error as? PresetStoreFailure, .unrecoverable)
        }
        try await degraded.reset.deleteCustomPresetStoreAndKey()

        let reopened = try await fixture.makeServices()
        let presets = try await reopened.customPresets.customPresets()
        XCTAssertTrue(presets.isEmpty)
        XCTAssertTrue(fixture.keys.storedServices.isEmpty)
        XCTAssertEqual(fixture.keys.createServices, [])
    }

    func testCorruptProviderMetadataStillPublishesBulkCredentialReset() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        try fixture.prepareRoot()
        await fixture.credentials.seed(
            account: UUID(),
            value: Data("SYNTHETIC_ORPHAN_CREDENTIAL".utf8)
        )
        try Data("malformed-provider-metadata".utf8).write(
            to: fixture.root.appendingPathComponent("providers.plist")
        )

        let degraded = try await fixture.makeServices()
        do {
            _ = try await degraded.providerManagement.descriptors()
            XCTFail("corrupt provider metadata must remain unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        try await degraded.reset.deleteProviderVaultAndCredentials()

        let credentialsAreEmpty = await fixture.credentials.isEmpty
        let reopened = try await fixture.makeServices()
        let providers = try await reopened.providerManagement.descriptors()
        XCTAssertTrue(credentialsAreEmpty)
        XCTAssertTrue(providers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("providers.plist").path
        ))
    }

    func testCorruptProviderResetRejectsMissingBoundDirectoryWithoutLosingMetadataAuthority() async throws {
        let fixture = try FactoryFixture()
        let moved = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "\(fixture.root.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: moved)
        }
        try fixture.prepareRoot()
        await fixture.credentials.seed(
            account: UUID(),
            value: Data("SYNTHETIC_ORPHAN_CREDENTIAL".utf8)
        )
        try Data("malformed-provider-metadata".utf8).write(
            to: fixture.root.appendingPathComponent("providers.plist")
        )

        let degraded = try await fixture.makeServices()
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        do {
            try await degraded.reset.deleteProviderVaultAndCredentials()
            XCTFail("missing bound metadata directory must fail provider reset")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("providers.plist").path
        ))
    }

    func testOversizedAuthoritiesStillPublishTheirResetOnlyRecoveryFacades() async throws {
        do {
            let fixture = try FactoryFixture()
            defer { fixture.removeFiles() }
            try fixture.prepareRoot()
            try writeSparseAuthority(
                fixture.root.appendingPathComponent("preferences.plist"),
                byteCount: PrivacyStorageResourceLimits
                    .preferencesEncodedBytes + 1
            )
            let services = try await fixture.makeServices()
            do {
                _ = try await services.preferences.snapshot()
                XCTFail("oversized preferences must be recovery-only")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .preferencesUnrecoverable
                )
            }
            try await services.reset.resetPreferences()
            _ = try await services.preferences.snapshot()
        }

        do {
            let fixture = try FactoryFixture()
            defer { fixture.removeFiles() }
            try fixture.prepareRoot()
            try writeSparseAuthority(
                fixture.root.appendingPathComponent("providers.plist"),
                byteCount: PrivacyStorageResourceLimits
                    .providerMetadataEncodedBytes + 1
            )
            let services = try await fixture.makeServices()
            do {
                _ = try await services.providerManagement.descriptors()
                XCTFail("oversized provider metadata must be recovery-only")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .providerRecoveryRequired
                )
            }
            try await services.reset.deleteProviderVaultAndCredentials()
            let descriptors = try await services.providerManagement.descriptors()
            XCTAssertTrue(descriptors.isEmpty)
        }

        do {
            let fixture = try FactoryFixture()
            defer { fixture.removeFiles() }
            try fixture.prepareRoot()
            fixture.keys.seed(
                service: "com.example.GlideTranslate.private-presets-key",
                account: "v1",
                data: Data(repeating: 7, count: 32)
            )
            try writeSparseAuthority(
                fixture.root.appendingPathComponent("private-presets.plist"),
                byteCount: PrivacyStorageResourceLimits
                    .customPresetsEncodedBytes + 1
            )
            let services = try await fixture.makeServices()
            do {
                _ = try await services.customPresets.customPresets()
                XCTFail("oversized preset storage must be recovery-only")
            } catch {
                XCTAssertEqual(error as? PresetStoreFailure, .unrecoverable)
            }
            try await services.reset.deleteCustomPresetStoreAndKey()
            let presets = try await services.customPresets.customPresets()
            XCTAssertTrue(presets.isEmpty)
        }
    }

    func testFactoryRejectsSymlinkedApplicationSupportAncestorWithoutRedirectedWrites() async throws {
        let base = try physicalTemporaryDirectory().appendingPathComponent(
            "GlideTranslate-T13-Symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let redirected = base.appendingPathComponent("redirected", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: redirected,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: redirected
        )
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            _ = try await PrivacyStorageFactory.make(
                configuration: PrivacyStorageConfiguration(
                    applicationSupportDirectory: alias.appendingPathComponent("Data"),
                    keychainServicePrefix: "com.example.GlideTranslate"
                ),
                clock: FactoryClock(),
                dependencies: PrivacyStorageFactoryDependencies(
                    symmetricKeys: FactoryMemoryKeyStore(),
                    providerCredentials: FactoryMemoryCredentialStore(),
                    installer: SameDirectoryAtomicInstaller()
                )
            )
            XCTFail("symlinked authority path must fail closed")
        } catch {
            XCTAssertEqual(
                error as? SanitizedFailure,
                .preferencesUnrecoverable
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: redirected.path),
            []
        )
    }

    func testPostFactoryDirectorySubstitutionRejectsEveryAtomicWritePath() async throws {
        let fixture = try FactoryFixture()
        let parent = fixture.root.deletingLastPathComponent()
        let moved = parent.appendingPathComponent(
            "\(fixture.root.lastPathComponent)-moved",
            isDirectory: true
        )
        let redirected = parent.appendingPathComponent(
            "\(fixture.root.lastPathComponent)-redirected",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: redirected)
        }
        let services = try await fixture.makeServices()
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(
            at: redirected,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root,
            withDestinationURL: redirected
        )

        do {
            try await services.preferences.update { snapshot in
                snapshot.historyEnabled = true
            }
            XCTFail("substituted preferences authority must reject writes")
        } catch {}
        do {
            _ = try await services.providerManagement.create(
                ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://example.invalid/v1")!,
                    model: "redirected"
                ),
                credential: nil
            )
            XCTFail("substituted provider authority must reject writes")
        } catch {}
        do {
            try await services.customPresets.save(CustomPreset(
                id: .custom(),
                name: "Redirected",
                explanation: "Redirected",
                template: "Translate {text}",
                targetLanguage: .identified("en"),
                action: .translate
            ))
            XCTFail("substituted preset authority must reject writes")
        } catch {}

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: redirected.path),
            []
        )
        XCTAssertEqual(fixture.keys.createServices, [])
    }

    func testPostFactoryOrdinaryDirectoryReplacementRejectsEveryAtomicWritePath() async throws {
        let fixture = try FactoryFixture()
        let parent = fixture.root.deletingLastPathComponent()
        let moved = parent.appendingPathComponent(
            "\(fixture.root.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: moved)
        }
        let services = try await fixture.makeServices()
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            try await services.preferences.update { snapshot in
                snapshot.historyEnabled = true
            }
            XCTFail("replacement preferences authority must reject writes")
        } catch {}
        do {
            _ = try await services.providerManagement.create(
                ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://example.invalid/v1")!,
                    model: "replacement"
                ),
                credential: nil
            )
            XCTFail("replacement provider authority must reject writes")
        } catch {}
        do {
            try await services.customPresets.save(CustomPreset(
                id: .custom(),
                name: "Replacement",
                explanation: "Replacement",
                template: "Translate {text}",
                targetLanguage: .identified("en"),
                action: .translate
            ))
            XCTFail("replacement preset authority must reject writes")
        } catch {}

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path),
            []
        )
        XCTAssertEqual(fixture.keys.createServices, [])
    }

    func testPostFactoryOrdinaryDirectoryReplacementCannotReportCompleteStorageReset() async throws {
        let fixture = try FactoryFixture()
        let parent = fixture.root.deletingLastPathComponent()
        let moved = parent.appendingPathComponent(
            "\(fixture.root.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: moved)
        }
        let services = try await fixture.makeServices()
        try await services.preferences.update { $0.historyEnabled = true }
        _ = try await services.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "seeded"
            ),
            credential: SensitiveCredentialInput("SYNTHETIC_CREDENTIAL")
        )
        try await services.customPresets.save(CustomPreset(
            id: .custom(),
            name: "Seeded",
            explanation: "Seeded",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        ))
        _ = try await services.history.recordCompleted(
            syntheticCompletion(),
            sourceApplication: nil
        )

        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        try await services.reset.closeStores()
        for operation in [
            { try await services.reset.deleteHistoryStoreAndKey() },
            { try await services.reset.deleteCustomPresetStoreAndKey() },
            { try await services.reset.deleteProviderVaultAndCredentials() },
            { try await services.reset.resetPreferences() }
        ] {
            do {
                try await operation()
                XCTFail("replacement authority must make reset stage fail")
            } catch {}
        }

        for name in [
            "preferences.plist",
            "providers.plist",
            "private-presets.plist",
            "history.sqlite"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: moved.appendingPathComponent(name).path
            ))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path),
            []
        )
        let credentialsAreEmpty = await fixture.credentials.isEmpty
        XCTAssertFalse(credentialsAreEmpty)
        XCTAssertEqual(fixture.keys.storedServices.count, 2)
    }

    func testPostFactoryRemovedDirectoryCannotReportCompleteStorageReset() async throws {
        let fixture = try FactoryFixture()
        let moved = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "\(fixture.root.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: moved)
        }
        let services = try await fixture.makeServices()
        try await services.preferences.update { $0.historyEnabled = true }
        _ = try await services.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "seeded"
            ),
            credential: SensitiveCredentialInput("SYNTHETIC_CREDENTIAL")
        )
        try await services.customPresets.save(CustomPreset(
            id: .custom(),
            name: "Seeded",
            explanation: "Seeded",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        ))
        _ = try await services.history.recordCompleted(
            syntheticCompletion(),
            sourceApplication: nil
        )
        try FileManager.default.moveItem(at: fixture.root, to: moved)

        try await services.reset.closeStores()
        for operation in [
            { try await services.reset.deleteHistoryStoreAndKey() },
            { try await services.reset.deleteCustomPresetStoreAndKey() },
            { try await services.reset.deleteProviderVaultAndCredentials() },
            { try await services.reset.resetPreferences() }
        ] {
            do {
                try await operation()
                XCTFail("missing bound authority must make reset stage fail")
            } catch {}
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        for name in [
            "preferences.plist",
            "providers.plist",
            "private-presets.plist",
            "history.sqlite"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: moved.appendingPathComponent(name).path
            ))
        }
        let credentialsAreEmpty = await fixture.credentials.isEmpty
        XCTAssertFalse(credentialsAreEmpty)
        XCTAssertEqual(fixture.keys.storedServices.count, 2)
    }

    func testFactoryReopensAllServicesAndDoesNotEagerlyCreateKeys() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }

        let first = try await fixture.makeServices()
        XCTAssertEqual(fixture.keys.createServices, [])

        let application = ApplicationIdentity(
            bundleIdentifier: "com.example.synthetic",
            displayName: "Synthetic"
        )
        try await first.preferences.update { snapshot in
            snapshot.historyEnabled = true
            snapshot.generalAutomaticApplications = [application]
        }
        _ = try await first.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "synthetic-model"
            ),
            credential: nil
        )
        let preset = CustomPreset(
            id: .custom(),
            name: "Synthetic",
            explanation: "Synthetic explanation",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        )
        try await first.customPresets.save(preset)
        let historyOutcome = try await first.history.recordCompleted(
            syntheticCompletion(),
            sourceApplication: application
        )

        XCTAssertEqual(historyOutcome, .stored)
        XCTAssertEqual(Set(fixture.keys.createServices), [
            "com.example.GlideTranslate.private-presets-key",
            "com.example.GlideTranslate.history-key"
        ])

        let reopened = try await fixture.makeServices()
        let snapshot = try await reopened.preferences.snapshot()
        let providers = try await reopened.providerManagement.descriptors()
        let presets = try await reopened.customPresets.customPresets()
        let history = try await reopened.history.search(.all)

        XCTAssertTrue(snapshot.historyEnabled)
        XCTAssertEqual(snapshot.generalAutomaticApplications, [application])
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(presets, [preset])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.sourcePreview, "SYNTHETIC_SOURCE")
    }

    func testTwoFactoryCallsShareOneAuthorityGraphWithoutLostUpdatesOrResetResurrection() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }

        let first = try await fixture.makeServices()
        let second = try await fixture.makeServices()
        let firstApplication = ApplicationIdentity(
            bundleIdentifier: "com.example.first",
            displayName: "First"
        )
        let secondApplication = ApplicationIdentity(
            bundleIdentifier: "com.example.second",
            displayName: "Second"
        )

        try await first.preferences.update { snapshot in
            snapshot.historyEnabled = true
            snapshot.generalAutomaticApplications = [
                firstApplication,
                secondApplication
            ]
        }
        try await second.preferences.update { snapshot in
            snapshot.automaticCaptureEnabled = true
        }
        var snapshot = try await first.preferences.snapshot()
        XCTAssertTrue(snapshot.historyEnabled)
        XCTAssertTrue(snapshot.automaticCaptureEnabled)

        let provider = try await first.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "first"
            ),
            credential: nil
        )
        let access = try await first.providerVault.access
            .accessDescriptor(provider.id)
        _ = try await first.providerVault.confirmation.commitConfirmation(
            id: provider.id,
            expectedConfigurationRevision: access.configurationRevision,
            expectedConfirmationRevision: access.confirmationRevision,
            proposedClass: .cloud
        )
        try await first.providerManagement.setAutomaticApplications(
            [firstApplication, secondApplication],
            for: provider.id
        )
        _ = try await second.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: "second"
            ),
            credential: nil
        )
        let descriptors = try await first.providerManagement.descriptors()
        XCTAssertEqual(descriptors.count, 2)

        try await second.preferences.update { snapshot in
            snapshot.generalAutomaticApplications = [firstApplication]
        }
        let automaticApplications = try await first.providerManagement
            .automaticApplications(for: provider.id)
        XCTAssertEqual(automaticApplications, [firstApplication])

        try await second.reset.resetPreferences()
        try await first.preferences.update { snapshot in
            snapshot.onboardingCompleted = true
        }
        snapshot = try await second.preferences.snapshot()
        XCTAssertTrue(snapshot.onboardingCompleted)
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertFalse(snapshot.automaticCaptureEnabled)
        XCTAssertTrue(snapshot.generalAutomaticApplications.isEmpty)
    }

    func testFactoryRecoversPendingProviderRecordBeforePublishingServices() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        let pendingID = ProviderConfigurationID()
        let repository = ProviderMetadataRepository(
            fileURL: fixture.root.appendingPathComponent("providers.plist")
        )
        try await repository.install(ProviderMetadataEnvelope(
            version: ProviderMetadataEnvelope.currentVersion,
            records: [ProviderConfigurationRecord(
                id: pendingID,
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "pending",
                confirmedClass: nil,
                configurationRevision: 1,
                confirmationRevision: 0,
                activeCredentialAccount: nil,
                pendingCredentialAccount: nil,
                cleanupCredentialAccounts: [],
                state: .pendingCredentialWrite
            )],
            offDeviceAuthorizations: [pendingID: []]
        ))

        let services = try await fixture.makeServices()
        let descriptors = try await services.providerManagement.descriptors()
        let authoritative = try await repository.load()

        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertTrue(authoritative.records.isEmpty)
        XCTAssertTrue(authoritative.offDeviceAuthorizations.isEmpty)
    }

    func testFactoryConstructsOneVaultThroughBothTypedHandleFacets() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        let services = try await fixture.makeServices()
        let descriptor = try await services.providerManagement
            .ensureDefaultOllamaConfiguration()

        let access = try await services.providerVault.access
            .accessDescriptor(descriptor.id)
        let commit = try await services.providerVault.confirmation
            .commitConfirmation(
                id: descriptor.id,
                expectedConfigurationRevision: access.configurationRevision,
                expectedConfirmationRevision: access.confirmationRevision,
                proposedClass: .cloud
            )

        XCTAssertEqual(access.id, descriptor.id)
        XCTAssertEqual(
            commit.confirmationRevision,
            access.confirmationRevision + 1
        )
    }

    func testCompleteResetDeletesOwnedAuthorityAndReopensDisabledEmpty() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        let services = try await fixture.makeServices()
        try await services.preferences.update { snapshot in
            snapshot.automaticCaptureEnabled = true
            snapshot.mouseSelectionEnabled = true
            snapshot.keyboardSelectionEnabled = true
            snapshot.clipboardFallbackEnabled = true
            snapshot.historyEnabled = true
            snapshot.generalAutomaticApplications = [ApplicationIdentity(
                bundleIdentifier: "com.example.synthetic",
                displayName: "Synthetic"
            )]
            snapshot.historyExcludedApplications = [ApplicationIdentity(
                bundleIdentifier: "com.example.excluded",
                displayName: "Excluded"
            )]
            snapshot.launchAtLogin = true
        }
        let provider = try await services.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "synthetic-model"
            ),
            credential: SensitiveCredentialInput("SYNTHETIC_CREDENTIAL")
        )
        let providerAccess = try await services.providerVault.access
            .accessDescriptor(provider.id)
        try await services.customPresets.save(CustomPreset(
            id: .custom(),
            name: "Synthetic",
            explanation: "Synthetic",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        ))
        _ = try await services.history.recordCompleted(
            syntheticCompletion(),
            sourceApplication: nil
        )
        let keyCreationCount = fixture.keys.createServices.count

        try await services.reset.closeStores()
        do {
            _ = try await services.providerVault.access
                .accessDescriptor(provider.id)
            XCTFail("retired provider access facet must reject reads")
        } catch {}
        do {
            _ = try await services.providerVault.confirmation.commitConfirmation(
                id: provider.id,
                expectedConfigurationRevision: providerAccess.configurationRevision,
                expectedConfirmationRevision: providerAccess.confirmationRevision,
                proposedClass: .cloud
            )
            XCTFail("retired provider confirmation facet must reject writes")
        } catch {}
        try await services.reset.deleteHistoryStoreAndKey()
        try await services.reset.deleteCustomPresetStoreAndKey()
        do {
            try await services.customPresets.save(CustomPreset(
                id: .custom(),
                name: "Interstage",
                explanation: "Interstage",
                template: "Translate {text}",
                targetLanguage: .identified("en"),
                action: .translate
            ))
            XCTFail("retired preset facade must reject interstage writes")
        } catch {}
        try await services.reset.deleteProviderVaultAndCredentials()
        try await services.reset.resetPreferences()

        let credentialsAreEmpty = await fixture.credentials.isEmpty
        XCTAssertTrue(credentialsAreEmpty)
        XCTAssertTrue(fixture.keys.storedServices.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("history.sqlite").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("private-presets.plist").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("providers.plist").path
        ))

        let reopened = try await fixture.makeServices()
        let resetSnapshot = try await reopened.preferences.snapshot()
        XCTAssertFalse(resetSnapshot.automaticCaptureEnabled)
        XCTAssertFalse(resetSnapshot.mouseSelectionEnabled)
        XCTAssertFalse(resetSnapshot.keyboardSelectionEnabled)
        XCTAssertFalse(resetSnapshot.clipboardFallbackEnabled)
        XCTAssertFalse(resetSnapshot.historyEnabled)
        XCTAssertFalse(resetSnapshot.launchAtLogin)
        XCTAssertTrue(resetSnapshot.generalAutomaticApplications.isEmpty)
        XCTAssertTrue(resetSnapshot.historyExcludedApplications.isEmpty)
        let resetProviders = try await reopened.providerManagement.descriptors()
        let resetPresets = try await reopened.customPresets.customPresets()
        let resetHistory = try await reopened.history.search(.all)
        XCTAssertTrue(resetProviders.isEmpty)
        XCTAssertTrue(resetPresets.isEmpty)
        XCTAssertTrue(resetHistory.isEmpty)
        XCTAssertEqual(fixture.keys.createServices.count, keyCreationCount)

        do {
            try await services.preferences.update { snapshot in
                snapshot.historyEnabled = true
            }
            XCTFail("retired preferences facade must reject writes")
        } catch {}
        do {
            _ = try await services.providerManagement.create(
                ProviderConfigurationDraft(
                    protocolKind: .ollamaNative,
                    endpoint: URL(string: "http://127.0.0.1:11434")!,
                    model: "retired"
                ),
                credential: nil
            )
            XCTFail("retired provider facade must reject writes")
        } catch {}
        do {
            try await services.customPresets.save(CustomPreset(
                id: .custom(),
                name: "Retired",
                explanation: "Retired",
                template: "Translate {text}",
                targetLanguage: .identified("en"),
                action: .translate
            ))
            XCTFail("retired preset facade must reject writes")
        } catch {}
        do {
            _ = try await services.history.search(.all)
            XCTFail("retired history facade must reject reads")
        } catch {}
        do {
            try await services.reset.resetPreferences()
            XCTFail("retired reset facade must reject operations")
        } catch {}

        let unchangedSnapshot = try await reopened.preferences.snapshot()
        let unchangedProviders = try await reopened.providerManagement.descriptors()
        let unchangedPresets = try await reopened.customPresets.customPresets()
        XCTAssertFalse(unchangedSnapshot.historyEnabled)
        XCTAssertTrue(unchangedProviders.isEmpty)
        XCTAssertTrue(unchangedPresets.isEmpty)
    }

    func testCompleteResetWaitsForActiveFacadeOperationBeforeClosingStores() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        let services = try await fixture.makeServices()
        let updateEntered = DispatchSemaphore(value: 0)
        let releaseUpdate = DispatchSemaphore(value: 0)
        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)

        let update = Task {
            try await services.preferences.update { snapshot in
                updateEntered.signal()
                releaseUpdate.wait()
                snapshot.historyEnabled = true
            }
        }
        XCTAssertEqual(updateEntered.wait(timeout: .now() + 1), .success)

        let close = Task {
            closeStarted.signal()
            try await services.reset.closeStores()
            closeFinished.signal()
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)

        releaseUpdate.signal()
        try await update.value
        try await close.value
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)

        try await services.reset.deleteHistoryStoreAndKey()
        try await services.reset.deleteCustomPresetStoreAndKey()
        try await services.reset.deleteProviderVaultAndCredentials()
        try await services.reset.resetPreferences()
    }

    func testFinalPreferencesResetFailureAllowsFreshGraphWhileOldResetRetries() async throws {
        let installer = FailOnceArmedPreferencesInstaller()
        let fixture = try FactoryFixture(installer: installer)
        defer { fixture.removeFiles() }
        let services = try await fixture.makeServices()
        try await services.preferences.update { snapshot in
            snapshot.historyEnabled = true
        }

        try await services.reset.closeStores()
        try await services.reset.deleteHistoryStoreAndKey()
        try await services.reset.deleteCustomPresetStoreAndKey()
        try await services.reset.deleteProviderVaultAndCredentials()
        installer.arm()

        do {
            try await services.reset.resetPreferences()
            XCTFail("armed final preferences reset must fail once")
        } catch {}

        let retained = try await fixture.makeServices()
        let retainedSnapshot = try await retained.preferences.snapshot()
        XCTAssertTrue(retainedSnapshot.historyEnabled)

        try await services.reset.resetPreferences()
        do {
            try await services.reset.resetPreferences()
            XCTFail("successful retry must retire the old reset facade")
        } catch {}
        let stillUsable = try await retained.preferences.snapshot()
        XCTAssertTrue(stillUsable.historyEnabled)

        try await retained.reset.closeStores()
        try await retained.reset.deleteHistoryStoreAndKey()
        try await retained.reset.deleteCustomPresetStoreAndKey()
        try await retained.reset.deleteProviderVaultAndCredentials()
        try await retained.reset.resetPreferences()

        do {
            _ = try await retained.preferences.snapshot()
            XCTFail("the replacement graph must retire after its own reset")
        } catch {
        }

        let reopened = try await fixture.makeServices()
        let snapshot = try await reopened.preferences.snapshot()
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertFalse(snapshot.automaticCaptureEnabled)
        XCTAssertTrue(snapshot.generalAutomaticApplications.isEmpty)
    }

    func testProviderResetKeepsRecoverableTombstoneUntilCredentialCleanupSucceeds() async throws {
        let fixture = try FactoryFixture()
        defer { fixture.removeFiles() }
        let services = try await fixture.makeServices()
        _ = try await services.providerManagement.create(
            ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "synthetic-model"
            ),
            credential: SensitiveCredentialInput("SYNTHETIC_CREDENTIAL")
        )
        await fixture.credentials.setDeleteFailureEnabled(true)

        do {
            try await services.reset.deleteProviderVaultAndCredentials()
            XCTFail("expected credential cleanup failure")
        } catch {
            XCTAssertEqual(
                error as? SanitizedFailure,
                .providerRecoveryRequired
            )
        }
        let repository = ProviderMetadataRepository(
            fileURL: fixture.root.appendingPathComponent("providers.plist")
        )
        let tombstone = try await repository.load()
        let visible = try await services.providerManagement.descriptors()
        let credentialsRemain = !(await fixture.credentials.isEmpty)
        XCTAssertEqual(tombstone.records.map(\.state), [.deletionPending])
        XCTAssertEqual(tombstone.records.first?.cleanupCredentialAccounts.count, 1)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(credentialsRemain)

        await fixture.credentials.setDeleteFailureEnabled(false)
        try await services.reset.deleteProviderVaultAndCredentials()
        let credentialsAreEmpty = await fixture.credentials.isEmpty
        XCTAssertTrue(credentialsAreEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("providers.plist").path
        ))
    }

    func testCloseStoresWaitsForInFlightHistoryWriteBeforeDeletionCanBegin() async throws {
        let preferences = GatedHistoryPreferences()
        let persistence = ResetConcurrencyHistoryPersistence()
        let history = DefaultTranslationHistory(
            preferences: preferences,
            clock: FactoryClock(),
            persistence: persistence
        )
        let write = Task {
            try await history.recordCompleted(
                syntheticCompletion(),
                sourceApplication: nil
            )
        }
        XCTAssertEqual(
            preferences.snapshotStarted.wait(timeout: .now() + 1),
            .success
        )

        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let close = Task {
            closeStarted.signal()
            try await history.closeForReset()
            closeFinished.signal()
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            closeFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )

        preferences.releaseFirstSnapshot()
        let writeOutcome = try await write.value
        XCTAssertEqual(writeOutcome, .stored)
        try await close.value
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(persistence.database.insertCount, 1)

        do {
            _ = try await history.recordCompleted(
                syntheticCompletion(),
                sourceApplication: nil
            )
            XCTFail("closed history must reject new writes")
        } catch {
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertEqual(persistence.database.insertCount, 1)
    }
}

private final class FactoryFixture: @unchecked Sendable {
    let root: URL
    let keys = FactoryMemoryKeyStore()
    let credentials = FactoryMemoryCredentialStore()
    private let clock = FactoryClock()
    private let installer: any AtomicDataInstalling

    init(
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller()
    ) throws {
        self.installer = installer
        root = try physicalTemporaryDirectory().appendingPathComponent(
            "GlideTranslate-T13-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func makeServices() async throws -> PrivacyStorageServices {
        try await PrivacyStorageFactory.make(
            configuration: PrivacyStorageConfiguration(
                applicationSupportDirectory: root,
                keychainServicePrefix: "com.example.GlideTranslate"
            ),
            clock: clock,
            dependencies: PrivacyStorageFactoryDependencies(
                symmetricKeys: keys,
                providerCredentials: credentials,
                installer: installer
            )
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

private final class FailOnceArmedPreferencesInstaller:
    AtomicDataInstalling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var didFail = false

    func arm() {
        lock.withLock { armed = true }
    }

    func install(_ data: Data, at destination: URL) throws {
        let shouldFail = lock.withLock {
            guard armed,
                  !didFail,
                  destination.lastPathComponent == "preferences.plist" else {
                return false
            }
            didFail = true
            return true
        }
        if shouldFail {
            throw AtomicInstallFailure.writeFailed
        }
        try SameDirectoryAtomicInstaller().install(data, at: destination)
    }
}

private final class FactoryMemoryKeyStore: SymmetricKeyStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var creations: [String] = []

    var createServices: [String] { lock.withLock { creations } }
    var storedServices: Set<String> { lock.withLock { Set(values.keys) } }

    func seed(service: String, account: String, data: Data) {
        lock.withLock { values["\(service)|\(account)"] = data }
    }

    func readKey(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service)|\(account)"] }
    }

    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        lock.withLock {
            let key = "\(service)|\(account)"
            if let value = values[key] {
                return SymmetricKeyMaterial(data: value, createdByCaller: false)
            }
            let value = Data(repeating: UInt8(creations.count + 1), count: 32)
            values[key] = value
            creations.append(service)
            return SymmetricKeyMaterial(data: value, createdByCaller: true)
        }
    }

    func deleteKey(service: String, account: String) throws {
        _ = lock.withLock {
            values.removeValue(forKey: "\(service)|\(account)")
        }
    }
}

private actor FactoryMemoryCredentialStore: ProviderCredentialStoring {
    private var values: [UUID: Data] = [:]
    private var deleteFailureEnabled = false

    var isEmpty: Bool { values.isEmpty }

    func setDeleteFailureEnabled(_ enabled: Bool) {
        deleteFailureEnabled = enabled
    }

    func seed(account: UUID, value: Data) {
        values[account] = value
    }

    func add(
        _ credential: borrowing SensitiveCredentialInput,
        account: UUID
    ) async throws {
        values[account] = Data(credential.value.utf8)
    }

    func delete(account: UUID) async throws {
        if deleteFailureEnabled {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        values.removeValue(forKey: account)
    }

    func deleteAll() async throws {
        if deleteFailureEnabled {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        values.removeAll()
    }

    func read(account: UUID) async throws -> Data {
        guard let value = values[account] else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        return value
    }
}

private struct FactoryClock: AppClock {
    let now = ContinuousClock().now
    let date = Date(timeIntervalSince1970: 2_000_000_000)

    func sleep(for duration: Duration) async throws {}
}

private final class GatedHistoryPreferences: PreferencesStore,
    @unchecked Sendable {
    let snapshotStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var didGate = false
    private var releaseRequested = false

    func snapshot() async throws -> PreferencesSnapshot {
        let shouldGate = lock.withLock {
            guard !didGate else { return false }
            didGate = true
            return true
        }
        if shouldGate {
            snapshotStarted.signal()
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if releaseRequested { return true }
                    firstContinuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        return snapshot
    }

    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {}

    func releaseFirstSnapshot() {
        let continuation = lock.withLock {
            let value = firstContinuation
            firstContinuation = nil
            if value == nil { releaseRequested = true }
            return value
        }
        continuation?.resume()
    }
}

private final class ResetConcurrencyHistoryPersistence:
    HistoryPersistenceOpening,
    @unchecked Sendable {
    let database = ResetConcurrencyHistoryDatabase()
    private let cipher = ResetConcurrencyHistoryCipher()

    func withExisting<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T? {
        try operation(HistoryRuntime(database: database, cipher: cipher))
    }

    func withWritable<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T {
        try operation(HistoryRuntime(database: database, cipher: cipher))
    }

    func clearAll() throws {}
}

private final class ResetConcurrencyHistoryDatabase: HistoryDatabaseAccess,
    @unchecked Sendable {
    private let lock = NSLock()
    private var inserts = 0

    var insertCount: Int { lock.withLock { inserts } }

    func insert(id: TranslationRecordID, envelope: HistoryEnvelope) throws {
        lock.withLock { inserts += 1 }
    }

    func fetchBatch(
        afterID: TranslationRecordID?,
        limit: Int
    ) throws -> [HistoryDatabaseRow] { [] }

    func deleteIDsInTransaction(_ ids: [TranslationRecordID]) throws {}
    func deleteAllInTransaction() throws {}
    func close() throws {}
}

private struct ResetConcurrencyHistoryCipher: HistoryCiphering {
    func seal(
        _ payload: HistoryPayload,
        id: TranslationRecordID
    ) throws -> HistoryEnvelope {
        HistoryEnvelope(version: 1, sealedCombined: Data([1]))
    }

    func openBatch(
        _ rows: [HistoryDatabaseRow]
    ) throws -> [DecryptedHistoryRow] { [] }
}

private func syntheticCompletion() -> CompletedTranslation {
    CompletedTranslation(
        requestID: TranslationRequestID(),
        sourceText: "SYNTHETIC_SOURCE",
        resultText: "SYNTHETIC_RESULT",
        presetID: PresetID(rawValue: "accurate-translation"),
        sourceLanguage: .identified("en"),
        targetLanguage: .identified("zh-Hans"),
        providerClass: .cloud
    )
}

private func writeSparseAuthority(_ url: URL, byteCount: Int) throws {
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(byteCount))
    try handle.close()
}

private func physicalTemporaryDirectory() throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(FileManager.default.temporaryDirectory.path, &buffer) != nil else {
        throw CocoaError(.fileReadUnknown)
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(
        fileURLWithPath: String(decoding: bytes, as: UTF8.self),
        isDirectory: true
    )
}
