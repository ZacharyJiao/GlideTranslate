import AppKit
import ModelProviders
@testable import PrivacyStorage
import SelectionCapture
import SharedSupport
import SwiftUI
import TranslationCore
import XCTest
@testable import GlideTranslate

final class ProductionCompositionTests: XCTestCase {
    func testOwnershipTableMatchesApprovedU10ContractExactly() {
        XCTAssertEqual(
            ProductionCompositionContract.rows,
            [
                .constructsOnce(.privacyStorage),
                .constructsOnce(.modelProviders),
                .constructsOnce(.translationEngine),
                .constructsOnce(.selectionAuthorization),
                .constructsOnce(.promptPresetFacade),
                .constructsOnce(.diagnosticExportCoordinator),
                .constructsOnce(.privacyResetService),
                .constructsOnce(.coordinator),
                .startsTriggersFromPreferences(mouse: false, keyboard: false),
                .routesMouseToCoordinatorExactlyOnce,
                .routesKeyboardToCoordinatorExactlyOnce,
                .routesShortcutToCoordinatorExactlyOnce,
                .schedulesHistoryMaintenanceAtLaunchAndEvery24Hours,
                .terminates(
                    cancel: 1,
                    stopMonitor: 1,
                    unregisterShortcut: 1,
                    closeStores: 1,
                    plaintextCacheCount: 0
                ),
            ]
        )
    }

    func testFailureRowsExposeOnlyTypedSafeStateAndStopAutomaticCapture() {
        XCTAssertEqual(
            ProductionCompositionContract.failureRows,
            [
                .init(failure: .corruptPreferences, automaticCaptureStopped: true),
                .init(failure: .providerVaultRecoveryRequired, automaticCaptureStopped: true),
                .init(failure: .shortcutConflict, automaticCaptureStopped: true),
                .init(failure: .historyMaintenanceFailure, automaticCaptureStopped: true),
                .init(failure: .captureUnavailable, automaticCaptureStopped: true),
                .init(failure: .partialShutdown, automaticCaptureStopped: true),
            ]
        )
    }

    @MainActor
    func testRootReferencesAreStableAcrossRepeatedSceneReads() {
        let fixture = ProductionCompositionRoot.developmentFixture()
        let firstScene = fixture.sceneState
        let firstSettings = fixture.settingsViewModel

        XCTAssertTrue(firstScene === fixture.sceneState)
        XCTAssertTrue(firstSettings === fixture.settingsViewModel)
        XCTAssertEqual(fixture.constructionCounts.values.reduce(0, +), 8)
        XCTAssertTrue(fixture.constructionCounts.values.allSatisfy { $0 == 1 })
    }

    @MainActor
    func testRootTerminationRetiresSettingsEffectWork() async {
        let fixture = ProductionCompositionRoot.developmentFixture()

        await fixture.terminate()

        XCTAssertTrue(fixture.settingsViewModel.externalEffectsRetired)
    }

    @MainActor
    func testRootTerminationDrainsSettingsProviderOperationAndRejectsLateWork() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let descriptor = SanitizedProviderDescriptor(
            id: providerID,
            protocolKind: .ollamaNative,
            privacyClass: .localOnDevice,
            hasCredential: false
        )
        let inspection = CompositionSuspendingInspection()
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(
                    snapshot: .appFixture(providerID: providerID)
                ),
                reset: CompositionReset(),
                providerManagement: CompositionProviderManagement(
                    descriptors: [descriptor]
                ),
                inspection: inspection
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )

        root.settingsViewModel.performOwned {
            await $0.testConnection(for: providerID)
        }
        await inspection.waitUntilConnectionSuspended()
        var terminationCompleted = false
        let termination = Task {
            await root.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        await inspection.resumeConnection()
        await termination.value
        XCTAssertTrue(terminationCompleted)

        var lateWorkRan = false
        root.settingsViewModel.performOwned { _ in lateWorkRan = true }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(lateWorkRan)
    }

    @MainActor
    func testRootTerminationDrainsSharedOnboardingProviderOperation() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let descriptor = SanitizedProviderDescriptor(
            id: providerID,
            protocolKind: .ollamaNative,
            privacyClass: .localOnDevice,
            hasCredential: false
        )
        var snapshot = PreferencesSnapshot.appFixture(providerID: providerID)
        snapshot.onboardingCompleted = false
        let inspection = CompositionSuspendingInspection()
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: snapshot),
                reset: CompositionReset(),
                providerManagement: CompositionProviderManagement(
                    descriptors: [descriptor]
                ),
                inspection: inspection
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        let onboarding = try XCTUnwrap(root.onboardingCoordinator)

        onboarding.performOwned { await $0.detectOllama() }
        await inspection.waitUntilDiscoverySuspended()
        var terminationCompleted = false
        let termination = Task {
            await root.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        await inspection.resumeDiscovery()
        await termination.value
        XCTAssertTrue(terminationCompleted)
    }

    func testProviderDisplayProjectionLoadsModelFromConfigurationDetail() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let sanitized = SanitizedProviderDescriptor(
            id: providerID,
            protocolKind: .openAICompatible,
            privacyClass: .cloud,
            hasCredential: true
        )
        let details = ProviderConfigurationDetails(
            id: providerID,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "detail-model",
            privacyClass: .cloud,
            hasCredential: true
        )
        let management = CompositionProviderManagement(
            descriptors: [sanitized],
            configurations: [details]
        )

        let displayed = try await ProductionSettingsProviderManager(
            management: management
        ).descriptors()

        XCTAssertEqual(displayed.first?.model, "detail-model")
        XCTAssertEqual(
            Set(Mirror(reflecting: sanitized).children.compactMap(\.label)),
            ["id", "protocolKind", "privacyClass", "hasCredential"]
        )
    }

    @MainActor
    func testSettingsResetDrainsProviderOperationBeforeResetAll() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let descriptor = SanitizedProviderDescriptor(
            id: providerID,
            protocolKind: .ollamaNative,
            privacyClass: .localOnDevice,
            hasCredential: false
        )
        let inspection = CompositionSuspendingInspection()
        let reset = CompositionSettingsReset(report: .completed)
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(
                    snapshot: .appFixture(providerID: providerID)
                ),
                reset: CompositionReset(),
                providerManagement: CompositionProviderManagement(
                    descriptors: [descriptor]
                ),
                inspection: inspection
            ),
            resetOverride: reset,
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )

        root.settingsViewModel.performOwned {
            await $0.testConnection(for: providerID)
        }
        await inspection.waitUntilConnectionSuspended()
        let resetting = Task { await root.settingsViewModel.confirmReset() }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(reset.count, 0)

        await inspection.resumeConnection()
        await resetting.value
        XCTAssertEqual(reset.count, 1)
        await root.retireAfterReset()
    }

    @MainActor
    func testRootTerminationDrainsDeferredProductionProjectionReconciliation() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let preferences = CompositionPreferences(
            snapshot: .appFixture(providerID: providerID)
        )
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: preferences,
                reset: CompositionReset()
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        await preferences.failNextUpdateAndAuthoritativeReadThenSuspendProjection()

        root.settingsViewModel.performOwned {
            await $0.setUILanguage(.simplifiedChinese)
        }
        await preferences.waitUntilProjectionSnapshotSuspended()
        var terminationCompleted = false
        let termination = Task {
            await root.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        await preferences.resumeProjectionSnapshot()
        await termination.value
        XCTAssertTrue(terminationCompleted)
    }

    @MainActor
    func testProductionCompositionPathConsumesOneInjectedCoreGraph() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let preferences = CompositionPreferences(
            snapshot: .appFixture(providerID: providerID)
        )
        let reset = CompositionReset()
        let builder = CompositionCoreBuilder(
            preferences: preferences,
            reset: reset
        )
        let diagnosticOrder = CompositionDiagnosticOrder()
        let settingsReset = CompositionSettingsReset(
            report: .partialFailure([.deleteProviderVault])
        )
        let replacement = CompositionReplacementRecorder()

        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: builder,
            diagnosticAdapters: ProductionDiagnosticAdapters(
                preview: CompositionDiagnosticPreview(order: diagnosticOrder),
                destination: CompositionDiagnosticDestination(order: diagnosticOrder),
                writer: CompositionDiagnosticWriter(order: diagnosticOrder)
            ),
            resetOverride: settingsReset,
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in
                let report = await reset.resetAll()
                replacement.record(report)
                return report
            }
        )

        let buildCount = await builder.buildCount
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(root.constructionCounts.count, CompositionComponent.allCases.count)
        XCTAssertTrue(root.constructionCounts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(
            root.sceneState.coordinator.manualInputViewModel.characterLimit,
            root.initialSnapshot?.selectionCharacterLimit
        )
        XCTAssertNil(root.onboardingCoordinator)

        await root.settingsViewModel.startDiagnostics()
        let diagnosticEvents = await diagnosticOrder.events
        XCTAssertEqual(diagnosticEvents, [.preview, .destination, .write])
        XCTAssertEqual(root.settingsViewModel.diagnosticsOutcome, .saved)

        await root.settingsViewModel.confirmReset()
        await root.settingsViewModel.confirmReset()
        let resetCount = settingsReset.count
        let replacementReports = replacement.reports
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(replacementReports, [.partialFailure([.deleteProviderVault])])
        XCTAssertEqual(
            root.settingsViewModel.resetReport,
            .partialFailure([.deleteProviderVault])
        )

        let custom = CustomPreset(
            id: .custom(),
            name: "User Preset Name",
            explanation: "Synthetic",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        )
        root.settingsViewModel.beginNewPrompt()
        await root.settingsViewModel.updatePromptDraft(custom)
        await root.settingsViewModel.savePromptDraft()
        let manualPreset = root.sceneState.manualInputViewModel.presetOptions.first {
            $0.id == custom.id
        }
        XCTAssertEqual(manualPreset?.label, custom.name)
        XCTAssertNil(manualPreset?.labelKey)
        XCTAssertTrue(root.sceneState.presetOptions.contains { $0.id == custom.id })
    }

    @MainActor
    func testProductionRootSeedsStoredProviderInventoryBeforeAnyReload() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let descriptor = SanitizedProviderDescriptor(
            id: providerID,
            protocolKind: .openAICompatible,
            privacyClass: .cloud,
            hasCredential: true
        )
        let management = CompositionProviderManagement(descriptors: [descriptor])
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(
                    snapshot: .appFixture(providerID: providerID)
                ),
                reset: CompositionReset(),
                providerManagement: management
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )

        XCTAssertEqual(root.settingsViewModel.providers, [
            SettingsProviderDescriptor(
                id: providerID,
                protocolKind: .openAICompatible,
                privacyClass: .cloud,
                hasCredential: true
            ),
        ])
        let descriptorReadCount = await management.descriptorReadCount
        XCTAssertEqual(descriptorReadCount, 1)
        await root.terminate()
    }

    @MainActor
    func testFirstLaunchOpensOnboardingWithoutRegisteringShortcutAndFinishDismissesIt() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        var snapshot = PreferencesSnapshot.appFixture(providerID: providerID)
        snapshot.onboardingCompleted = false
        snapshot.automaticCaptureEnabled = false
        let preferences = CompositionPreferences(snapshot: snapshot)
        let shortcut = CompositionShortcutRegistrar()
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: preferences,
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor() },
                makeShortcutRegistrar: { _ in shortcut }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )

        let onboarding = try XCTUnwrap(root.onboardingCoordinator)
        await root.start()
        let registerCount = await shortcut.registerCount
        XCTAssertEqual(registerCount, 0)
        XCTAssertEqual(root.sceneState.shortcutSettingsModel.state, .unregistered)
        XCTAssertEqual(root.sceneState.onboardingPresenter.openRequestCount, 1)

        for _ in 0..<4 { onboarding.skip() }
        XCTAssertEqual(onboarding.step, .complete)
        await onboarding.finish()
        XCTAssertEqual(root.sceneState.onboardingPresenter.dismissRequestCount, 1)
        let stored = try await preferences.snapshot()
        XCTAssertTrue(stored.onboardingCompleted)
        await root.terminate()
    }

    @MainActor
    func testOnboardingOpenRequestActivatesApplicationAfterOpeningWindow() {
        let presenter = OnboardingWindowPresenter()
        var events: [String] = []

        presenter.open()
        presenter.consumePendingRequests(
            openWindow: { events.append("open:\($0)") },
            dismissWindow: { events.append("dismiss:\($0)") },
            activateApplication: { events.append("activate") }
        )
        presenter.consumePendingRequests(
            openWindow: { events.append("open:\($0)") },
            dismissWindow: { events.append("dismiss:\($0)") },
            activateApplication: { events.append("activate") }
        )

        XCTAssertEqual(events, ["open:onboarding", "activate"])
    }

    @MainActor
    func testSettingsPresenterReusesOneOwnedWindowAcrossAllOpenRoutes() async {
        let window = SettingsWindowFixture()
        var factoryCount = 0
        let presenter = SettingsWindowPresenter { _ in
            factoryCount += 1
            return window
        }
        presenter.installContent { AnyView(EmptyView()) }

        presenter.open()
        presenter.openSystemSettings()
        for _ in 0..<20 where window.presentationCount < 2 {
            await Task.yield()
        }

        XCTAssertEqual(presenter.requestCount, 1)
        XCTAssertEqual(presenter.systemOpenRequestCount, 1)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(window.presentationCount, 2)
    }

    @MainActor
    func testPostCoreCompositionFailureRetiresInjectedStorageGraph() async {
        let preferences = CompositionPreferences(
            snapshot: .appFixture(providerID: ProviderConfigurationID(rawValue: UUID())),
            failSnapshot: true
        )
        let reset = CompositionReset()
        let builder = CompositionCoreBuilder(
            preferences: preferences,
            reset: reset
        )

        do {
            _ = try await ProductionCompositionRoot.make(
                bundle: .main,
                coreBuilder: builder,
                applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                performResetAndReplace: { reset in await reset.resetAll() }
            )
            XCTFail("post-core failure must not publish a root")
        } catch {}

        let closeCount = await reset.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testMenuMutationAndCatalogReloadShareAuthoritativeStoredSnapshot() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let preferences = CompositionPreferences(snapshot: .appFixture(providerID: providerID))
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: preferences,
                reset: CompositionReset()
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )

        await root.sceneState.coordinator.setAutomaticCapturePaused(true)
        XCTAssertFalse(root.settingsViewModel.snapshot.automaticCaptureEnabled)

        await root.settingsViewModel.reloadProviders()

        XCTAssertFalse(root.settingsViewModel.snapshot.automaticCaptureEnabled)
        XCTAssertEqual(root.sceneState.captureState, .paused)
    }

    @MainActor
    func testProductionLifecyclePublishesMaintenanceAndMonitorFailures() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let preferences = CompositionPreferences(snapshot: .appFixture(providerID: providerID))
        let lifecycleStates = CompositionLifecycleStates()
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: preferences,
                reset: CompositionReset(),
                history: CompositionHistory(failMaintenance: true)
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor() },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar() }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        root.observeLifecycleSafeState { lifecycleStates.append($0) }

        await root.start()

        XCTAssertEqual(lifecycleStates.last, .historyMaintenanceUnavailable)
        XCTAssertEqual(
            ProductionStartupSafeState(lifecycleState: lifecycleStates.last ?? .ready),
            .failed(.historyMaintenanceFailure)
        )
        XCTAssertEqual(root.sceneState.captureState, .historyUnavailable)
        XCTAssertEqual(root.sceneState.menuModel.recoveryTextKeyName, "menu.resolveInSettings")
        await root.terminate()

        let monitorFailureStates = CompositionLifecycleStates()
        let monitorFailureRoot = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: .appFixture(providerID: providerID)),
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor(failStart: true) },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar() }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        monitorFailureRoot.observeLifecycleSafeState { monitorFailureStates.append($0) }

        await monitorFailureRoot.start()

        XCTAssertEqual(monitorFailureStates.last, .captureUnavailable)
        XCTAssertEqual(
            ProductionStartupSafeState(lifecycleState: monitorFailureStates.last ?? .ready),
            .failed(.captureUnavailable)
        )
        XCTAssertEqual(monitorFailureRoot.sceneState.captureState, .captureUnavailable)
        await monitorFailureRoot.terminate()
    }

    @MainActor
    func testStartupAndRuntimeShortcutConflictsPublishSafeLifecycleState() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let startupStates = CompositionLifecycleStates()
        let startupConflictRoot = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: .appFixture(providerID: providerID)),
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor() },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar(failInitial: true) }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        startupConflictRoot.observeLifecycleSafeState { startupStates.append($0) }
        await startupConflictRoot.start()
        XCTAssertEqual(startupStates.last, .shortcutReplacementRequired)
        XCTAssertEqual(startupConflictRoot.sceneState.captureState, .shortcutUnavailable)
        await startupConflictRoot.terminate()

        let runtimeStates = CompositionLifecycleStates()
        let runtimeConflictRoot = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: .appFixture(providerID: providerID)),
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor() },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar(conflictOnReplacement: true) }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        runtimeConflictRoot.observeLifecycleSafeState { runtimeStates.append($0) }
        await runtimeConflictRoot.start()
        await runtimeConflictRoot.settingsViewModel.setShortcut(
            ShortcutDescriptor(keyCode: 3, modifiers: 0x0008_0000)
        )

        XCTAssertEqual(runtimeStates.last, .shortcutReplacementRequired)
        XCTAssertEqual(runtimeConflictRoot.lifecycle?.safeState, .shortcutReplacementRequired)
        XCTAssertEqual(runtimeConflictRoot.sceneState.captureState, .shortcutUnavailable)
        await runtimeConflictRoot.terminate()
    }

    @MainActor
    func testPrepareForResetPublishesResettingMenuState() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: .appFixture(providerID: providerID)),
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in CompositionMonitor() },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar() }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        await root.start()

        await root.lifecycle?.prepareForReset()

        XCTAssertEqual(root.lifecycle?.safeState, .resetting)
        XCTAssertEqual(root.sceneState.captureState, .resetting)
        XCTAssertFalse(root.sceneState.menuModel.captureToggleEnabled)
        await root.retireAfterReset()
    }

    @MainActor
    func testPrepareForResetPublishesBeforeSuspendedMonitorStopReturns() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        let monitor = CompositionSuspendingStopMonitor()
        let root = try await ProductionCompositionRoot.make(
            bundle: .main,
            coreBuilder: CompositionCoreBuilder(
                preferences: CompositionPreferences(snapshot: .appFixture(providerID: providerID)),
                reset: CompositionReset()
            ),
            triggerAdapters: ProductionTriggerAdapters(
                makeMonitor: { _ in monitor },
                makeShortcutRegistrar: { _ in CompositionShortcutRegistrar() }
            ),
            applicationSupportDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            performResetAndReplace: { reset in await reset.resetAll() }
        )
        await root.start()

        let preparation = Task { await root.lifecycle?.prepareForReset() }
        await monitor.waitUntilStopStarted()

        XCTAssertEqual(root.sceneState.captureState, .resetting)
        XCTAssertFalse(root.sceneState.menuModel.captureToggleEnabled)

        await monitor.resumeStop()
        await preparation.value
        await root.retireAfterReset()
    }

    @MainActor
    func testResetReplacementFailurePublishesAppLevelReportPresentation() async {
        let report = ResetReport.partialFailure([.deleteProviderVault, .resetPreferences])
        let delegate = AppDelegate(productionRootFactory: { _ in
            throw SanitizedFailure.preferencesUnrecoverable
        })
        let reset = CompositionSettingsReset(report: report)

        do {
            _ = try await delegate.performResetAndReplace(using: reset)
            XCTFail("Expected runtime replacement failure")
        } catch let failure as SettingsRuntimeRefreshFailure {
            XCTAssertEqual(failure.report, report)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(reset.count, 1)
        XCTAssertEqual(delegate.lastResetReport, report)
        XCTAssertEqual(
            delegate.resetFailurePresentation,
            ProductionResetFailurePresentation(
                runtimeFailure: .corruptPreferences,
                report: report
            )
        )
        XCTAssertNil(delegate.composition)
    }

    @MainActor
    func testObservedProductionRootRendersReplacementAfterDelegatePublishesComposition() async throws {
        let loadingAppeared = expectation(description: "startup content appeared")
        let readyAppeared = expectation(description: "production content appeared")
        loadingAppeared.assertForOverFulfill = false
        readyAppeared.assertForOverFulfill = false
        let root = ProductionCompositionRoot.developmentFixture()
        let delegate = AppDelegate(productionRootFactory: { _ in root })
        let host = NSHostingView(rootView: ObservedProductionRoot(
            appDelegate: delegate,
            ready: { _ in
                Color.clear.onAppear { readyAppeared.fulfill() }
            },
            unavailable: { _ in
                Color.clear.onAppear { loadingAppeared.fulfill() }
            }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
        host.layoutSubtreeIfNeeded()

        await fulfillment(of: [loadingAppeared], timeout: 2)
        _ = try await delegate.performResetAndReplace(
            using: CompositionSettingsReset(report: .completed)
        )
        await fulfillment(of: [readyAppeared], timeout: 2)
        await root.terminate()
    }
}

private actor CompositionCoreBuilder: ProductionCoreBuilding {
    private(set) var buildCount = 0
    let preferences: CompositionPreferences
    let reset: CompositionReset
    let promptPersistence = CompositionPresetPersistence()
    let history: any TranslationHistory
    let providerManagement: any ProviderManagement
    let inspection: any ProviderInspection

    init(
        preferences: CompositionPreferences,
        reset: CompositionReset,
        history: any TranslationHistory = CompositionHistory(),
        providerManagement: any ProviderManagement = CompositionProviderManagement(),
        inspection: any ProviderInspection = CompositionInspection()
    ) {
        self.preferences = preferences
        self.reset = reset
        self.history = history
        self.providerManagement = providerManagement
        self.inspection = inspection
    }

    func build(
        applicationSupportDirectory: URL,
        keychainServicePrefix: String,
        clock: any AppClock,
        diagnostics: any ProviderDiagnosticReporting
    ) async throws -> ProductionCoreServices {
        buildCount += 1
        let preflight = CompositionPreflight()
        return ProductionCoreServices(
            storage: ProductionStorageFacades(
                preferences: preferences,
                providerManagement: providerManagement,
                history: history,
                reset: reset
            ),
            providers: ModelProviderServices(
                preflight: preflight,
                confirmation: CompositionConfirmation(),
                service: CompositionProviderService(),
                inspection: inspection
            ),
            engine: CompositionEngine(),
            presets: DefaultPromptPresetStore(
                persistence: promptPersistence,
                validation: DefaultPromptPresetValidationService()
            ),
            capture: SelectionCaptureServices(
                systemSelectionProcessor: CompositionSelectionProcessor(),
                authorizationGate: CompositionAuthorizationGate()
            ),
            constructionCounts: [
                .privacyStorage: 1,
                .modelProviders: 1,
                .translationEngine: 1,
                .selectionAuthorization: 1,
                .promptPresetFacade: 1,
            ]
        )
    }
}

private actor CompositionPreferences: PreferencesStore {
    private var value: PreferencesSnapshot
    private let failSnapshot: Bool
    private var failNextUpdate = false
    private var snapshotFailuresRemaining = 0
    private var suspendProjectionSnapshot = false
    private var projectionSnapshotSuspended = false
    private var projectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var projectionContinuation: CheckedContinuation<Void, Never>?
    init(snapshot: PreferencesSnapshot, failSnapshot: Bool = false) {
        value = snapshot
        self.failSnapshot = failSnapshot
    }
    func snapshot() async throws -> PreferencesSnapshot {
        if failSnapshot { throw SanitizedFailure.preferencesUnrecoverable }
        if snapshotFailuresRemaining > 0 {
            snapshotFailuresRemaining -= 1
            throw SanitizedFailure.preferencesUnrecoverable
        }
        if suspendProjectionSnapshot {
            suspendProjectionSnapshot = false
            projectionSnapshotSuspended = true
            let waiters = projectionWaiters
            projectionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { projectionContinuation = $0 }
        }
        return value
    }
    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        if failNextUpdate {
            failNextUpdate = false
            throw SanitizedFailure.preferencesUnrecoverable
        }
        try transform(&value)
    }

    func failNextUpdateAndAuthoritativeReadThenSuspendProjection() {
        failNextUpdate = true
        snapshotFailuresRemaining = 1
        suspendProjectionSnapshot = true
    }

    func waitUntilProjectionSnapshotSuspended() async {
        if projectionSnapshotSuspended { return }
        await withCheckedContinuation { projectionWaiters.append($0) }
    }

    func resumeProjectionSnapshot() {
        projectionContinuation?.resume()
        projectionContinuation = nil
    }
}

private actor CompositionReset: PrivacyDataResetting {
    private(set) var closeCount = 0
    func closeStores() async throws { closeCount += 1 }
    func deleteHistoryStoreAndKey() async throws {}
    func deleteCustomPresetStoreAndKey() async throws {}
    func deleteProviderVaultAndCredentials() async throws {}
    func resetPreferences() async throws {}
}

private actor CompositionProviderManagement: ProviderManagement {
    private let descriptorValues: [SanitizedProviderDescriptor]
    private let configurationValues: [ProviderConfigurationID: ProviderConfigurationDetails]
    private(set) var descriptorReadCount = 0

    init(
        descriptors: [SanitizedProviderDescriptor] = [],
        configurations: [ProviderConfigurationDetails] = []
    ) {
        descriptorValues = descriptors
        configurationValues = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.id, $0) }
        )
    }

    func descriptors() async throws -> [SanitizedProviderDescriptor] {
        descriptorReadCount += 1
        return descriptorValues
    }
    func configuration(_ id: ProviderConfigurationID) async throws -> ProviderConfigurationDetails {
        if let configuration = configurationValues[id] {
            return configuration
        }
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func create(
        _ draft: ProviderConfigurationDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SanitizedProviderDescriptor {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func update(
        _ id: ProviderConfigurationID,
        draft: ProviderConfigurationDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SanitizedProviderDescriptor {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func ensureDefaultOllamaConfiguration() async throws -> SanitizedProviderDescriptor {
        guard let descriptor = descriptorValues.first else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        return descriptor
    }
    func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> { [] }
    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {}
    func delete(_ id: ProviderConfigurationID) async throws {}
}

private actor CompositionHistory: TranslationHistory {
    let failMaintenance: Bool
    init(failMaintenance: Bool = false) {
        self.failMaintenance = failMaintenance
    }
    func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome { .skipped(.disabled) }
    func search(_ query: HistoryQuery) async throws -> [HistorySummary] { [] }
    func performMaintenance() async throws {
        if failMaintenance { throw SanitizedFailure.historyUnrecoverable }
    }
    func delete(_ id: TranslationRecordID) async throws {}
    func clearAll() async throws {}
}

private actor CompositionMonitor: SelectionTriggerMonitoring {
    let failStart: Bool
    init(failStart: Bool = false) { self.failStart = failStart }
    func start(mouseEnabled: Bool, keyboardEnabled: Bool) async throws {
        if failStart { throw SanitizedFailure.providerProtocolFailure }
    }
    func stop() async {}
}

private actor CompositionSuspendingStopMonitor: SelectionTriggerMonitoring {
    private var stopStarted = false
    private var didSuspendStop = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start(mouseEnabled: Bool, keyboardEnabled: Bool) async throws {}

    func stop() async {
        guard !didSuspendStop else { return }
        didSuspendStop = true
        stopStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func waitUntilStopStarted() async {
        if stopStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor CompositionShortcutRegistrar: GlobalShortcutRegistering {
    let failInitial: Bool
    let conflictOnReplacement: Bool
    private var initialDescriptor: ShortcutDescriptor?
    private(set) var registerCount = 0

    init(failInitial: Bool = false, conflictOnReplacement: Bool = false) {
        self.failInitial = failInitial
        self.conflictOnReplacement = conflictOnReplacement
    }

    func register(_ descriptor: ShortcutDescriptor) async throws {
        registerCount += 1
        if initialDescriptor == nil {
            if failInitial { throw ShortcutRegistrationFailure.conflict }
            initialDescriptor = descriptor
            return
        }
        if conflictOnReplacement, descriptor != initialDescriptor {
            throw ShortcutRegistrationFailure.conflict
        }
    }

    func unregister() async {}
}

@MainActor
private final class CompositionLifecycleStates {
    private(set) var values: [AppLifecycleSafeState] = []
    var last: AppLifecycleSafeState? { values.last }
    func append(_ state: AppLifecycleSafeState) { values.append(state) }
}

private actor CompositionPreflight: ProviderPreflight {
    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        .failure(.modelUnavailable)
    }
    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }
}

private actor CompositionConfirmation: ProviderConfirmationService {
    func prepareConfirmation(
        for id: ProviderConfigurationID
    ) async throws -> ProviderConfirmationChallenge {
        throw SanitizedFailure.destinationReconfirmationRequired
    }
    func confirm(
        _ challenge: ProviderConfirmationChallenge
    ) async throws -> ProviderDestinationSnapshot {
        throw SanitizedFailure.destinationReconfirmationRequired
    }
}

private actor CompositionProviderService: ProviderService {
    func generate(
        _ request: TranslationRequest,
        authorizedDestination: ProviderDestinationSnapshot
    ) async -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor CompositionInspection: ProviderInspection {
    func discoverModels(
        for configurationID: ProviderConfigurationID
    ) async throws -> [String] { [] }
    func testConnection(for configurationID: ProviderConfigurationID) async throws {}
}

private actor CompositionSuspendingInspection: ProviderInspection {
    private var connectionSuspended = false
    private var discoverySuspended = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    private var discoveryContinuation: CheckedContinuation<Void, Never>?

    func discoverModels(
        for configurationID: ProviderConfigurationID
    ) async throws -> [String] {
        discoverySuspended = true
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { discoveryContinuation = $0 }
        return ["synthetic-model"]
    }

    func testConnection(for configurationID: ProviderConfigurationID) async throws {
        connectionSuspended = true
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { connectionContinuation = $0 }
    }

    func waitUntilConnectionSuspended() async {
        if connectionSuspended { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func waitUntilDiscoverySuspended() async {
        if discoverySuspended { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func resumeConnection() {
        connectionContinuation?.resume()
        connectionContinuation = nil
    }

    func resumeDiscovery() {
        discoveryContinuation?.resume()
        discoveryContinuation = nil
    }
}

private actor CompositionEngine: TranslationEngine {
    func translate(
        _ intent: AuthorizedTranslationIntent
    ) async -> AsyncStream<TranslationUpdate> { AsyncStream { $0.finish() } }
    func retry(
        _ requestID: TranslationRequestID
    ) async -> AsyncStream<TranslationUpdate> { AsyncStream { $0.finish() } }
    func cancel(_ requestID: TranslationRequestID) async {}
}

private actor CompositionPresetPersistence: CustomPresetPersistence {
    private var values: [CustomPreset] = []
    func customPresets() async throws -> [CustomPreset] { values }
    func save(_ preset: CustomPreset) async throws {
        values.removeAll { $0.id == preset.id }
        values.append(preset)
    }
    func delete(_ id: PresetID) async throws {
        values.removeAll { $0.id == id }
    }
}

private actor CompositionSelectionProcessor: SystemSelectionProcessing {
    func process(
        trigger: CaptureTrigger,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome { .rejected(.noValidSelection) }
}

private actor CompositionAuthorizationGate: SelectionAuthorizationGate {
    func authorizeSystemSelection(
        trigger: CaptureTrigger,
        context: ForegroundApplicationContext,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome { .rejected(.noValidSelection) }
    func authorizeManualSubmission(
        _ submission: ManualTranslationSubmission,
        policy: SendPolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome { .rejected(.noValidSelection) }
}

private actor CompositionDiagnosticOrder {
    enum Event: Equatable { case preview, destination, write }
    private(set) var events: [Event] = []
    func append(_ event: Event) { events.append(event) }
}

@MainActor
private final class CompositionDiagnosticPreview: DiagnosticPreviewPresenting {
    let order: CompositionDiagnosticOrder
    init(order: CompositionDiagnosticOrder) { self.order = order }
    func show(_ preview: DiagnosticPreview) async -> Bool {
        await order.append(.preview)
        return true
    }
}

@MainActor
private final class CompositionDiagnosticDestination: DiagnosticDestinationPicking {
    let order: CompositionDiagnosticOrder
    init(order: CompositionDiagnosticOrder) { self.order = order }
    func chooseDestination() async -> URL? {
        await order.append(.destination)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-diagnostics.json")
    }
}

private actor CompositionDiagnosticWriter: DiagnosticFileWriting {
    let order: CompositionDiagnosticOrder
    init(order: CompositionDiagnosticOrder) { self.order = order }
    func write(_ data: Data, to url: URL) async throws {
        await order.append(.write)
    }
}

@MainActor
private final class CompositionSettingsReset: SettingsResetting {
    private(set) var count = 0
    let report: ResetReport
    init(report: ResetReport) { self.report = report }
    func resetAll() async -> ResetReport {
        count += 1
        return report
    }
}

@MainActor
private final class CompositionReplacementRecorder {
    private(set) var reports: [ResetReport] = []
    func record(_ report: ResetReport) { reports.append(report) }
}

@MainActor
private final class SettingsWindowFixture: SettingsWindowDisplaying {
    private(set) var presentationCount = 0
    func present() { presentationCount += 1 }
}
