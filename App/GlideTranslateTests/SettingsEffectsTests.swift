import ModelProviders
import PrivacyStorage
import SelectionCapture
import SharedSupport
import SwiftUI
import XCTest

@testable import GlideTranslate

@MainActor
final class SettingsEffectsTests: XCTestCase {
    private enum Effect: Equatable {
        case preferencesWrite
        case shortcutRegister
        case shortcutUnregister
        case serviceManagementRegister
        case serviceManagementUnregister
        case narrowMouseMonitor
        case narrowKeyMonitor
        case accessibilityStatusRead
        case accessibilityPrompt
        case accessibilitySettingsOpen
        case vaultCreate
        case vaultUpdate
        case vaultDelete
        case authorizationDelete
        case resolve
        case confirm
        case tcpTLS
        case getTags
        case vaultApplicationsRead
        case vaultApplicationsWrite(Set<ApplicationIdentity>)
    }

    func testRenderingAllSectionsHasNoEffect() {
        let fixture = Fixture()
        for section in SettingsSection.allCases {
            let host = NSHostingView(rootView: SettingsRootView(
                viewModel: fixture.model,
                initialSection: section
            ))
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
        }
        XCTAssertEqual(fixture.recorder.effects, [])
    }

    func testAccessibilityStateAndActionsAreExplicitAndProductionMonitorKeepsBothFlags() async throws {
        let fixture = Fixture()
        fixture.selection.status = .granted
        fixture.model.refreshAccessibilityStatus()
        XCTAssertEqual(fixture.model.accessibilityStatus, .granted)
        fixture.model.requestAccessibility()
        fixture.model.openAccessibilitySettings()
        XCTAssertEqual(fixture.recorder.effects, [
            .accessibilityStatusRead, .accessibilityPrompt, .accessibilitySettingsOpen,
        ])

        let monitor = Monitor()
        let access = AccessibilityClient()
        let controller = ProductionSettingsSelectionController(
            monitor: monitor,
            accessibility: access,
            mouseEnabled: false,
            keyboardEnabled: false
        )
        try await controller.setMouseEnabled(true)
        try await controller.setKeyboardEnabled(true)
        try await controller.setMouseEnabled(false)
        let configurations = await monitor.configurations
        XCTAssertEqual(configurations, [
            Monitor.Configuration(mouse: true, keyboard: false),
            Monitor.Configuration(mouse: true, keyboard: true),
            Monitor.Configuration(mouse: false, keyboard: true),
        ])
    }

    func testIncompleteOnboardingCannotInstallSelectionMonitors() async throws {
        let monitor = Monitor()
        let controller = ProductionSettingsSelectionController(
            monitor: monitor,
            accessibility: AccessibilityClient(),
            activationAllowed: false,
            automaticEnabled: true,
            mouseEnabled: false,
            keyboardEnabled: false
        )

        try await controller.setMouseEnabled(true)
        try await controller.setKeyboardEnabled(true)
        let beforeCompletion = await monitor.configurations
        XCTAssertEqual(beforeCompletion, [])

        try await controller.setActivationAllowed(true)
        let afterCompletion = await monitor.configurations
        XCTAssertEqual(
            afterCompletion,
            [.init(mouse: true, keyboard: true)]
        )
    }

    func testProductionSelectionControllerReloadsMenuPauseBeforeSettingsToggle() async throws {
        let providerID = ProviderConfigurationID(rawValue: UUID())
        var initial = PreferencesSnapshot.appFixture(providerID: providerID)
        initial.automaticCaptureEnabled = true
        initial.mouseSelectionEnabled = true
        initial.keyboardSelectionEnabled = false
        let preferences = SelectionPreferences(value: initial)
        let lifecycle = CaptureLifecycleRecorder()
        let controller = ProductionSettingsSelectionController(
            lifecycle: lifecycle,
            preferences: preferences,
            accessibility: AccessibilityClient(),
            initialSnapshot: initial
        )
        try await preferences.update { $0.automaticCaptureEnabled = false }

        try await controller.setKeyboardEnabled(true)

        XCTAssertEqual(lifecycle.snapshots.count, 1)
        XCTAssertFalse(lifecycle.snapshots[0].automatic)
        XCTAssertTrue(lifecycle.snapshots[0].mouse)
        XCTAssertTrue(lifecycle.snapshots[0].keyboard)
    }

    func testGeneralPreferenceBindingsRoundTripWithoutCouplingUILanguageAndTarget() async {
        let fixture = Fixture()
        let providerID = fixture.provider.id

        await fixture.model.setUILanguage(.simplifiedChinese)
        XCTAssertEqual(fixture.preferences.value.uiLanguage, .simplifiedChinese)
        XCTAssertEqual(fixture.preferences.value.defaultTargetLanguage, .identified("en"))

        await fixture.model.setTargetLanguage(.identified("ja"))
        await fixture.model.setDefaultPreset(PresetID(rawValue: "synthetic-preset"))
        await fixture.model.setDefaultProvider(providerID)
        await fixture.model.setAutomaticCaptureEnabled(false)

        XCTAssertEqual(fixture.preferences.value.defaultTargetLanguage, .identified("ja"))
        XCTAssertEqual(fixture.preferences.value.defaultPresetID, PresetID(rawValue: "synthetic-preset"))
        XCTAssertEqual(fixture.preferences.value.defaultProviderID, providerID)
        XCTAssertFalse(fixture.preferences.value.automaticCaptureEnabled)
        XCTAssertEqual(fixture.recorder.effects, Array(repeating: .preferencesWrite, count: 5))
    }

    func testExplicitSelectionAndLaunchActionsHaveExactEffects() async {
        let fixture = Fixture()

        await fixture.model.setAutomaticCaptureEnabled(false)
        await fixture.model.setMouseSelectionEnabled(false)
        await fixture.model.setKeyboardSelectionEnabled(false)
        await fixture.model.setClipboardFallbackEnabled(true, disclosureVisible: true)
        await fixture.model.setLaunchAtLogin(true)

        XCTAssertEqual(fixture.recorder.effects, [
            .preferencesWrite,
            .narrowMouseMonitor, .preferencesWrite,
            .narrowKeyMonitor, .preferencesWrite,
            .preferencesWrite,
            .serviceManagementRegister, .preferencesWrite,
        ])
    }

    func testShortcutAndLaunchFailuresRollBackDisplayedState() async {
        let fixture = Fixture(shortcutFailure: .conflict)
        let oldShortcut = fixture.model.snapshot.shortcut
        await fixture.model.setShortcut(ShortcutDescriptor(keyCode: 3, modifiers: oldShortcut.modifiers))
        XCTAssertEqual(fixture.model.snapshot.shortcut, oldShortcut)
        XCTAssertEqual(fixture.model.safeError, .shortcutUnavailable)

        fixture.launch.failNext = true
        await fixture.model.setLaunchAtLogin(true)
        XCTAssertFalse(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.model.safeError, .launchAtLoginUnavailable)
        XCTAssertEqual(fixture.recorder.effects, [
            .shortcutRegister, .shortcutRegister, .serviceManagementRegister,
        ])
    }

    func testShortcutPreferenceFailureRestoresPreviousRegistrationAndDisplay() async {
        let fixture = Fixture()
        let previous = fixture.model.snapshot.shortcut
        let replacement = ShortcutDescriptor(keyCode: 3, modifiers: previous.modifiers)
        fixture.preferences.failNext = true

        await fixture.model.setShortcut(replacement)

        XCTAssertEqual(fixture.model.snapshot.shortcut, previous)
        XCTAssertEqual(fixture.model.shortcutLabel, "⌥⇧D")
        XCTAssertEqual(fixture.model.safeError, .persistenceFailed)
        XCTAssertEqual(fixture.recorder.effects, [
            .shortcutRegister, .preferencesWrite, .shortcutRegister,
        ])
    }

    func testHostedGeneralShortcutRecorderSurfacesConflictAndMapsLocalChord() async {
        let descriptor = ShortcutRecorderField.descriptor(
            keyCode: 3,
            modifierFlags: [.option, .shift]
        )
        XCTAssertEqual(descriptor, ShortcutDescriptor(
            keyCode: 3,
            modifiers: ShortcutDescriptor.defaultOptionShiftD.modifiers
        ))
        XCTAssertNil(ShortcutRecorderField.descriptor(keyCode: 3, modifierFlags: []))

        let fixture = Fixture(shortcutFailure: .conflict, shortcutFailureOnce: true)
        let view = GeneralSettingsView(viewModel: fixture.model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        host.layoutSubtreeIfNeeded()
        let recorder = try! XCTUnwrap(firstDescendant(
            of: ShortcutRecorderButton.self,
            in: host
        ))
        XCTAssertEqual(view.shortcutPresentation, .ready)

        fixture.model.recordShortcutCandidate(descriptor!)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(recorder.title, descriptor!.displayLabel)

        await fixture.model.setShortcut(descriptor!)
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(recorder.title, ShortcutDescriptor.defaultOptionShiftD.displayLabel)
        XCTAssertEqual(view.shortcutPresentation, .replacementRequired)
    }

    func testLaunchRegisterAndUnregisterAreOnlyCalledFromToggleActions() async {
        let fixture = Fixture()
        await fixture.model.setLaunchAtLogin(true)
        await fixture.model.setLaunchAtLogin(false)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
            .serviceManagementUnregister, .preferencesWrite,
        ])
    }

    func testLaunchUnregisterFailureKeepsEnabledState() async {
        let fixture = Fixture()
        await fixture.model.setLaunchAtLogin(true)
        fixture.recorder.reset()
        fixture.launch.failNext = true

        await fixture.model.setLaunchAtLogin(false)

        XCTAssertTrue(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.model.safeError, .launchAtLoginUnavailable)
        XCTAssertEqual(fixture.recorder.effects, [.serviceManagementUnregister])
    }

    func testLaunchPreferenceFailureCompensatesServiceAndKeepsState() async {
        let fixture = Fixture()
        fixture.preferences.failNext = true

        await fixture.model.setLaunchAtLogin(true)

        XCTAssertFalse(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.model.safeError, .persistenceFailed)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
            .serviceManagementUnregister,
        ])
    }

    func testCommittedPreferenceWithProjectionFailureDoesNotCompensateEffect() async {
        let fixture = Fixture()
        fixture.preferences.failNextSnapshot = true

        await fixture.model.setLaunchAtLogin(true)

        XCTAssertTrue(fixture.preferences.value.launchAtLogin)
        XCTAssertFalse(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.model.safeError, .persistenceFailed)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
        ])
    }

    func testThrownUpdateWhoseAuthoritativeValueCommittedDoesNotCompensateEffect() async {
        let fixture = Fixture()
        fixture.preferences.commitThenFailNext = true

        await fixture.model.setLaunchAtLogin(true)

        XCTAssertTrue(fixture.preferences.value.launchAtLogin)
        XCTAssertTrue(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.model.safeError, .persistenceFailed)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
        ])
    }

    func testUnknownLaunchOutcomeReconcilesEffectAfterAuthoritativeRetry() async {
        let fixture = Fixture()
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        let effectReconciled = expectation(description: "launch effect reconciled")
        fixture.launch.disabled = { effectReconciled.fulfill() }

        await fixture.model.setLaunchAtLogin(true)
        await fulfillment(of: [effectReconciled], timeout: 1)

        XCTAssertFalse(fixture.preferences.value.launchAtLogin)
        XCTAssertFalse(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
            .serviceManagementUnregister,
        ])
    }

    func testUnknownShortcutOutcomeReconcilesRegistrationAfterAuthoritativeRetry() async {
        let fixture = Fixture()
        let previous = ShortcutDescriptor.defaultOptionShiftD
        let candidate = ShortcutDescriptor(keyCode: 3, modifiers: 0x0008_0000)
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        let effectReconciled = expectation(description: "shortcut effect reconciled")
        await fixture.registrar.setRegisteredObserver { descriptor in
            if descriptor == previous { effectReconciled.fulfill() }
        }

        await fixture.model.setShortcut(candidate)
        await fulfillment(of: [effectReconciled], timeout: 1)

        XCTAssertEqual(fixture.preferences.value.shortcut, previous)
        XCTAssertEqual(fixture.model.snapshot.shortcut, previous)
        XCTAssertEqual(fixture.shortcut.currentDescriptor, previous)
        XCTAssertEqual(fixture.recorder.effects, [
            .shortcutRegister, .preferencesWrite, .shortcutRegister,
        ])
    }

    func testNewerLaunchChoiceWinsWhileUnknownOutcomeRetryIsSuspended() async {
        let fixture = Fixture()
        let suspension = SnapshotSuspension()
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        fixture.preferences.snapshotSuspension = suspension

        await fixture.model.setLaunchAtLogin(true)
        await suspension.waitUntilStarted()
        let newerChoice = Task { await fixture.model.setLaunchAtLogin(false) }
        await Task.yield()
        await suspension.resume()
        await newerChoice.value

        XCTAssertFalse(fixture.preferences.value.launchAtLogin)
        XCTAssertFalse(fixture.model.snapshot.launchAtLogin)
        XCTAssertEqual(fixture.recorder.effects, [
            .serviceManagementRegister, .preferencesWrite,
            .serviceManagementUnregister,
            .serviceManagementUnregister, .preferencesWrite,
        ])
    }

    func testNewerShortcutChoiceWinsWhileUnknownOutcomeRetryIsSuspended() async {
        let fixture = Fixture()
        let previous = ShortcutDescriptor.defaultOptionShiftD
        let first = ShortcutDescriptor(keyCode: 3, modifiers: 0x0008_0000)
        let newer = ShortcutDescriptor(keyCode: 4, modifiers: 0x0008_0000)
        let suspension = SnapshotSuspension()
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        fixture.preferences.snapshotSuspension = suspension

        await fixture.model.setShortcut(first)
        await suspension.waitUntilStarted()
        let newerChoice = Task { await fixture.model.setShortcut(newer) }
        await Task.yield()
        await suspension.resume()
        await newerChoice.value

        XCTAssertEqual(fixture.preferences.value.shortcut, newer)
        XCTAssertEqual(fixture.model.snapshot.shortcut, newer)
        XCTAssertEqual(fixture.shortcut.currentDescriptor, newer)
        XCTAssertEqual(fixture.recorder.effects, [
            .shortcutRegister, .preferencesWrite,
            .shortcutRegister,
            .shortcutRegister, .preferencesWrite,
        ])
        XCTAssertNotEqual(fixture.shortcut.currentDescriptor, previous)
    }

    func testUnknownShortcutRestorationFailurePublishesUnavailableState() async {
        let publication = ShortcutPublicationProbe()
        let published = expectation(description: "shortcut lifecycle state published")
        let fixture = Fixture(snapshotChanged: { _ in
            publication.record()
            published.fulfill()
        })
        publication.shortcut = fixture.shortcut
        await fixture.registrar.failStartingWithAttempt(2)
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true

        await fixture.model.setShortcut(
            ShortcutDescriptor(keyCode: 3, modifiers: 0x0008_0000)
        )
        await fulfillment(of: [published], timeout: 1)

        XCTAssertEqual(fixture.shortcut.state, .unavailable)
        XCTAssertEqual(publication.states.last, .unavailable)
        XCTAssertEqual(fixture.model.safeError, .shortcutUnavailable)
    }

    func testResetDrainsSuspendedLaunchRetryBeforeTeardownUnregister() async {
        let fixture = Fixture()
        let suspension = SnapshotSuspension()
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        fixture.preferences.snapshotSuspension = suspension
        fixture.runtimeRefresh.teardown = .launch

        await fixture.model.setLaunchAtLogin(true)
        await suspension.waitUntilStarted()
        let reset = Task { await fixture.model.confirmReset() }
        await Task.yield()
        await suspension.resume()
        await reset.value
        let settledEffects = fixture.recorder.effects
        await Task.yield()

        XCTAssertTrue(fixture.model.externalEffectsRetired)
        XCTAssertEqual(fixture.recorder.effects, settledEffects)
        XCTAssertEqual(settledEffects, [
            .serviceManagementRegister, .preferencesWrite,
            .serviceManagementUnregister,
            .serviceManagementUnregister,
        ])
    }

    func testTerminationDrainPreventsSuspendedShortcutRetryAfterUnregister() async {
        let fixture = Fixture()
        let suspension = SnapshotSuspension()
        fixture.preferences.failNext = true
        fixture.preferences.failNextSnapshot = true
        fixture.preferences.snapshotSuspension = suspension

        await fixture.model.setShortcut(
            ShortcutDescriptor(keyCode: 3, modifiers: 0x0008_0000)
        )
        await suspension.waitUntilStarted()
        let teardown = Task {
            await fixture.model.retireExternalEffects()
            await fixture.registrar.unregister()
        }
        await Task.yield()
        await suspension.resume()
        await teardown.value
        let settledEffects = fixture.recorder.effects
        await Task.yield()

        XCTAssertTrue(fixture.model.externalEffectsRetired)
        XCTAssertEqual(fixture.recorder.effects, settledEffects)
        XCTAssertEqual(settledEffects, [
            .shortcutRegister, .preferencesWrite,
            .shortcutRegister, .shortcutUnregister,
        ])
    }

    func testClipboardDisclosureAndApplicationIdentityValidationPrecedeWrites() async {
        let fixture = Fixture()
        await fixture.model.setClipboardFallbackEnabled(true, disclosureVisible: false)
        await fixture.model.addGeneralApplication(bundleIdentifier: "", displayName: "")
        XCTAssertEqual(fixture.recorder.effects, [])

        await fixture.model.addGeneralApplication(
            bundleIdentifier: "example.app",
            displayName: "First"
        )
        await fixture.model.addGeneralApplication(
            bundleIdentifier: "example.app",
            displayName: "Renamed"
        )
        XCTAssertEqual(fixture.model.snapshot.generalAutomaticApplications, [
            ApplicationIdentity(bundleIdentifier: "example.app", displayName: "Renamed"),
        ])
        XCTAssertEqual(fixture.recorder.effects, [
            .preferencesWrite, .preferencesWrite,
        ])
    }

    func testProviderCreateStableUpdateCredentialChoicesAndResetApplications() async {
        let fixture = Fixture()
        let draft = fixture.cloudDraft

        fixture.model.setCredentialInput("synthetic-secret")
        await fixture.model.saveProvider(id: nil, draft: draft, credentialDisposition: .replace)
        XCTAssertEqual(fixture.provider.createHadCredential, [true])
        XCTAssertEqual(fixture.model.automaticApplications, [])

        for disposition in SettingsCredentialDisposition.allCases {
            if disposition == .replace {
                fixture.model.setCredentialInput("replacement-secret")
            }
            await fixture.model.saveProvider(
                id: fixture.provider.id,
                draft: draft,
                credentialDisposition: disposition
            )
        }

        XCTAssertEqual(fixture.provider.updatedIDs, Array(repeating: fixture.provider.id, count: 3))
        XCTAssertEqual(fixture.provider.credentialChanges, [.preserve, .remove, .replace])
        XCTAssertEqual(fixture.recorder.effects, [
            .vaultCreate, .resolve,
            .vaultUpdate, .resolve,
            .vaultUpdate, .resolve,
            .vaultUpdate, .resolve,
        ])
    }

    func testInitialProviderInventoryIsVisibleWithoutAnExplicitReload() {
        let providerID = ProviderConfigurationID()
        let initial = SettingsProviderDescriptor(
            id: providerID,
            protocolKind: .ollamaNative,
            privacyClass: .localOnDevice,
            hasCredential: false
        )
        let fixture = Fixture(initialProviders: [initial])

        XCTAssertEqual(fixture.model.providers, [initial])
    }

    func testProviderSaveFailureKeepsStableVisibleStateAndCredentialChoiceExplicit() async {
        let fixture = Fixture()
        fixture.provider.failNextMutation = true
        fixture.model.setCredentialInput("synthetic-secret")
        await fixture.model.saveProvider(
            id: fixture.provider.id,
            draft: fixture.cloudDraft,
            credentialDisposition: .replace
        )
        XCTAssertTrue(fixture.model.providers.isEmpty)
        XCTAssertEqual(fixture.model.safeError, .providerUnavailable)
        XCTAssertFalse(fixture.model.credentialFieldIsEmpty)
    }

    func testDestinationConfirmationRequiresPreviewAndChangedChallengeCannotWrite() async {
        let fixture = Fixture()
        let descriptor = fixture.provider.descriptor

        await fixture.model.prepareConfirmation(for: descriptor)
        XCTAssertNotNil(fixture.model.confirmationPreview)
        XCTAssertEqual(fixture.recorder.effects, [.resolve])

        await fixture.model.confirmDestination()
        XCTAssertNil(fixture.model.confirmationPreview)
        XCTAssertEqual(fixture.recorder.effects, [.resolve, .confirm, .authorizationDelete])

        fixture.recorder.reset()
        fixture.confirmation.changedOnConfirm = true
        await fixture.model.prepareConfirmation(for: descriptor)
        await fixture.model.confirmDestination()
        XCTAssertEqual(fixture.recorder.effects, [.resolve])
        XCTAssertEqual(fixture.model.safeError, .confirmationChanged)
        XCTAssertNil(fixture.model.confirmationPreview)
    }

    func testUnresolvedSavedProviderHasExplicitPrepareRouteAndProviderSwitchClearsScopedState() async {
        let fixture = Fixture()
        await fixture.model.saveProvider(
            id: nil,
            draft: fixture.cloudDraft,
            credentialDisposition: .preserve
        )
        let unresolved = try! XCTUnwrap(fixture.model.providers.first)
        XCTAssertEqual(unresolved.privacyClass, .unresolvedOrChanged)
        XCTAssertTrue(ModelsSettingsView.canPrepareConfirmation(for: unresolved))
        _ = NSHostingView(rootView: ModelsSettingsView(viewModel: fixture.model))
        XCTAssertEqual(fixture.model.confirmationPreview?.configurationID, unresolved.id)

        let allowed = ApplicationIdentity(bundleIdentifier: "example.allowed", displayName: "Allowed")
        fixture.preferences.value.generalAutomaticApplications = [allowed]
        fixture.provider.applications = [allowed]
        await fixture.model.loadAutomaticApplications(for: unresolved.id)
        XCTAssertEqual(fixture.model.automaticApplicationsProviderID, unresolved.id)

        await fixture.model.saveProvider(
            id: unresolved.id,
            draft: fixture.cloudDraft,
            credentialDisposition: .preserve
        )
        XCTAssertEqual(fixture.model.confirmationPreview?.configurationID, unresolved.id)
        XCTAssertTrue(fixture.model.discoveredModels.isEmpty)
        XCTAssertTrue(fixture.model.automaticApplications.isEmpty)
        XCTAssertNil(fixture.model.automaticApplicationsProviderID)
        XCTAssertEqual(fixture.model.selectedProvider?.id, unresolved.id)
        XCTAssertEqual(fixture.model.selectedProvider?.endpoint, fixture.cloudDraft.endpoint)
        XCTAssertEqual(fixture.model.selectedProvider?.model, fixture.cloudDraft.model)
        XCTAssertNil(fixture.model.safeError)

        await fixture.model.prepareConfirmation(for: unresolved)
        await fixture.model.loadAutomaticApplications(for: unresolved.id)

        await fixture.model.selectProvider(fixture.provider.secondID)
        _ = NSHostingView(rootView: ModelsSettingsView(viewModel: fixture.model))
        XCTAssertNil(fixture.model.confirmationPreview)
        XCTAssertTrue(fixture.model.automaticApplications.isEmpty)
        XCTAssertNil(fixture.model.automaticApplicationsProviderID)
        fixture.recorder.reset()

        await fixture.model.confirmDestination()
        XCTAssertEqual(fixture.recorder.effects, [])
        XCTAssertEqual(fixture.model.safeError, .confirmationChanged)
    }

    func testDiscoveryResultsRemainUserSelectableAndDeleteClearsSelection() async {
        let fixture = Fixture()
        await fixture.model.selectProvider(fixture.provider.id)
        await fixture.model.discoverModels(for: fixture.provider.id)
        XCTAssertEqual(fixture.model.discoveredModels, ["synthetic-model"])
        _ = NSHostingView(rootView: ModelsSettingsView(viewModel: fixture.model))

        await fixture.model.deleteProvider(fixture.provider.id)
        XCTAssertNil(fixture.model.selectedProvider)
        XCTAssertTrue(fixture.model.discoveredModels.isEmpty)
    }

    func testSlowDiscoveryCannotPopulateASecondProvider() async {
        let fixture = Fixture()
        let inspector = DelayedInspector(slowID: fixture.provider.id)
        let model = SettingsViewModel(
            initialSnapshot: fixture.preferences.value,
            preferences: fixture.preferences,
            shortcut: fixture.shortcut,
            launchAtLogin: fixture.launch,
            selection: fixture.selection,
            provider: fixture.provider,
            inspection: inspector,
            confirmation: fixture.confirmation
        )
        await model.selectProvider(fixture.provider.id)
        let slow = Task { await model.discoverModels(for: fixture.provider.id) }
        await inspector.waitUntilSlowRequestStarts()

        await model.selectProvider(fixture.provider.secondID)
        await model.discoverModels(for: fixture.provider.secondID)
        await inspector.resumeSlowRequest()
        await slow.value

        XCTAssertEqual(model.activeProviderID, fixture.provider.secondID)
        XCTAssertEqual(model.discoveredModels, ["model-b"])
    }

    func testConnectionTestsUseOnlyProtocolSpecificContentFreeEffects() async {
        let fixture = Fixture()
        fixture.inspection.protocolKinds[fixture.provider.id] = .openAICompatible
        await fixture.model.testConnection(for: fixture.provider.id)
        XCTAssertEqual(fixture.recorder.effects, [.resolve, .tcpTLS])

        fixture.recorder.reset()
        fixture.inspection.protocolKinds[fixture.provider.id] = .ollamaNative
        await fixture.model.testConnection(for: fixture.provider.id)
        XCTAssertEqual(fixture.recorder.effects, [.resolve, .getTags])
        XCTAssertEqual(fixture.inspection.chatRequestCount, 0)
    }

    func testAutomaticApplicationsAreIntersectedOnReadAndCommitDespiteCleanupFailure() async {
        let fixture = Fixture()
        let allowed = ApplicationIdentity(bundleIdentifier: "example.allowed", displayName: "Allowed")
        let stale = ApplicationIdentity(bundleIdentifier: "example.stale", displayName: "Stale")
        fixture.preferences.value.generalAutomaticApplications = [allowed]
        fixture.provider.applications = [allowed, stale]
        fixture.provider.failApplicationWrite = true

        await fixture.model.selectProvider(fixture.provider.id)
        fixture.recorder.reset()
        await fixture.model.loadAutomaticApplications(for: fixture.provider.id)
        XCTAssertEqual(fixture.model.automaticApplications, [allowed])
        XCTAssertEqual(fixture.recorder.effects, [
            .vaultApplicationsRead, .vaultApplicationsWrite([allowed]),
        ])

        fixture.recorder.reset()
        fixture.provider.failApplicationWrite = false
        await fixture.model.setAutomaticApplications([allowed, stale], for: fixture.provider.id)
        XCTAssertEqual(fixture.provider.applications, [allowed])
        XCTAssertEqual(fixture.model.automaticApplications, [allowed])
        XCTAssertEqual(fixture.recorder.effects, [.vaultApplicationsWrite([allowed])])
    }

    func testDeleteProviderOwnsVaultAndAuthorizationDeletionOnly() async {
        let fixture = Fixture()
        await fixture.model.deleteProvider(fixture.provider.id)
        XCTAssertEqual(fixture.recorder.effects, [.vaultDelete, .authorizationDelete])
    }

    func testBoundsRejectWithoutWritesAndTimeoutsPersistTogether() async {
        let fixture = Fixture()
        await fixture.model.setSelectionDebounceMilliseconds(99)
        await fixture.model.setSelectionCharacterLimit(20_001)
        await fixture.model.setTimeouts(connection: 0, firstToken: 120, streamIdle: 30)
        XCTAssertEqual(fixture.recorder.effects, [])
        XCTAssertEqual(fixture.model.safeError, .invalidValue)

        await fixture.model.setSelectionDebounceMilliseconds(100)
        await fixture.model.setSelectionCharacterLimit(20_000)
        await fixture.model.setTimeouts(connection: 60, firstToken: 600, streamIdle: 120)
        XCTAssertEqual(fixture.recorder.effects, Array(repeating: .preferencesWrite, count: 3))
    }

    private func firstDescendant<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType { return match }
        for subview in view.subviews {
            if let match = firstDescendant(of: type, in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private final class Fixture {
        let recorder = Recorder()
        let preferences: Preferences
        let registrar: Registrar
        let shortcut: ShortcutSettingsModel
        let launch: LaunchController
        let selection: SelectionController
        let provider: ProviderManager
        let inspection: Inspector
        let confirmation: Confirmation
        let runtimeRefresh: TeardownRuntimeRefresh
        let model: SettingsViewModel

        var cloudDraft: SettingsProviderDraft {
            SettingsProviderDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "synthetic-model"
            )
        }

        init(
            shortcutFailure: ShortcutRegistrationFailure? = nil,
            shortcutFailureOnce: Bool = false,
            initialProviders: [SettingsProviderDescriptor] = [],
            snapshotChanged:
                (@MainActor @Sendable (PreferencesSnapshot) async -> Void)? = nil
        ) {
            let providerID = ProviderConfigurationID()
            preferences = Preferences(
                value: .appFixture(providerID: providerID),
                recorder: recorder
            )
            registrar = Registrar(
                failure: shortcutFailure,
                failureOnce: shortcutFailureOnce,
                recorder: recorder
            )
            shortcut = ShortcutSettingsModel(
                registrar: registrar,
                currentDescriptor: .defaultOptionShiftD
            )
            launch = LaunchController(recorder: recorder)
            selection = SelectionController(recorder: recorder)
            provider = ProviderManager(id: providerID, recorder: recorder)
            inspection = Inspector(recorder: recorder)
            confirmation = Confirmation(recorder: recorder)
            runtimeRefresh = TeardownRuntimeRefresh(
                launch: launch,
                registrar: registrar
            )
            model = SettingsViewModel(
                initialSnapshot: preferences.value,
                preferences: preferences,
                shortcut: shortcut,
                launchAtLogin: launch,
                selection: selection,
                provider: provider,
                inspection: inspection,
                confirmation: confirmation,
                runtimeRefresh: runtimeRefresh,
                initialProviders: initialProviders,
                snapshotChanged: snapshotChanged
            )
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Effect] = []
        var effects: [Effect] { lock.withLock { storage } }
        func append(_ effect: Effect) { lock.withLock { storage.append(effect) } }
        func reset() { lock.withLock { storage = [] } }
    }

    private final class Preferences: PreferencesStore, @unchecked Sendable {
        private let lock = NSLock()
        private let recorder: Recorder
        private var storage: PreferencesSnapshot
        var failNext = false
        var commitThenFailNext = false
        var failNextSnapshot = false
        var snapshotSuspension: SnapshotSuspension?
        var value: PreferencesSnapshot {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }

        init(value: PreferencesSnapshot, recorder: Recorder) {
            storage = value
            self.recorder = recorder
        }

        func snapshot() async throws -> PreferencesSnapshot {
            let value = try lock.withLock {
                if failNextSnapshot {
                    failNextSnapshot = false
                    throw SanitizedFailure.preferencesUnrecoverable
                }
                return storage
            }
            if let snapshotSuspension {
                self.snapshotSuspension = nil
                await snapshotSuspension.suspend()
            }
            return value
        }

        func update(
            _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
        ) async throws {
            recorder.append(.preferencesWrite)
            if failNext {
                failNext = false
                throw SanitizedFailure.preferencesUnrecoverable
            }
            try lock.withLock { try transform(&storage) }
            if commitThenFailNext {
                commitThenFailNext = false
                throw SanitizedFailure.preferencesUnrecoverable
            }
        }
    }

    private actor Registrar: GlobalShortcutRegistering {
        let failure: ShortcutRegistrationFailure?
        let failureOnce: Bool
        let recorder: Recorder
        var hasFailed = false
        var registered: (@Sendable (ShortcutDescriptor) -> Void)?
        var attemptCount = 0
        var failStartingAtAttempt: Int?

        init(
            failure: ShortcutRegistrationFailure?,
            failureOnce: Bool,
            recorder: Recorder
        ) {
            self.failure = failure
            self.failureOnce = failureOnce
            self.recorder = recorder
        }

        func setRegisteredObserver(
            _ observer: @escaping @Sendable (ShortcutDescriptor) -> Void
        ) {
            registered = observer
        }

        func failStartingWithAttempt(_ attempt: Int) {
            failStartingAtAttempt = attempt
        }

        func register(_ descriptor: ShortcutDescriptor) async throws {
            attemptCount += 1
            recorder.append(.shortcutRegister)
            registered?(descriptor)
            if let failStartingAtAttempt,
               attemptCount >= failStartingAtAttempt {
                throw ShortcutRegistrationFailure.unavailable
            }
            if let failure, !failureOnce || !hasFailed {
                hasFailed = true
                throw failure
            }
        }

        func unregister() async { recorder.append(.shortcutUnregister) }
    }

    private actor SnapshotSuspension {
        private var started = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class ShortcutPublicationProbe {
        weak var shortcut: ShortcutSettingsModel?
        private(set) var states: [ShortcutRegistrationState] = []
        func record() {
            if let shortcut { states.append(shortcut.state) }
        }
    }

    @MainActor
    private final class TeardownRuntimeRefresh: SettingsRuntimeRefreshing {
        enum Teardown { case none, launch, shortcut }
        let launch: LaunchController
        let registrar: Registrar
        var teardown = Teardown.none

        init(launch: LaunchController, registrar: Registrar) {
            self.launch = launch
            self.registrar = registrar
        }

        func resetAndReplace(
            using reset: any SettingsResetting
        ) async throws -> ResetReport {
            switch teardown {
            case .none:
                break
            case .launch:
                try await launch.setEnabled(false)
            case .shortcut:
                await registrar.unregister()
            }
            return await reset.resetAll()
        }
    }

    @MainActor
    private final class LaunchController: SettingsLaunchAtLoginControlling {
        let recorder: Recorder
        var failNext = false
        var disabled: (@Sendable () -> Void)?
        init(recorder: Recorder) { self.recorder = recorder }

        func setEnabled(_ enabled: Bool) async throws {
            recorder.append(enabled ? .serviceManagementRegister : .serviceManagementUnregister)
            if !enabled { disabled?() }
            if failNext {
                failNext = false
                throw SanitizedFailure.preferencesUnrecoverable
            }
        }
    }

    @MainActor
    private final class SelectionController: SettingsSelectionControlling {
        let recorder: Recorder
        var status = SettingsAccessibilityStatus.unknown
        init(recorder: Recorder) { self.recorder = recorder }
        func setMouseEnabled(_ enabled: Bool) async throws { recorder.append(.narrowMouseMonitor) }
        func setKeyboardEnabled(_ enabled: Bool) async throws { recorder.append(.narrowKeyMonitor) }
        func accessibilityStatus() -> SettingsAccessibilityStatus {
            recorder.append(.accessibilityStatusRead)
            return status
        }
        func openAccessibilitySettings() { recorder.append(.accessibilitySettingsOpen) }
        func requestAccessibility() -> SettingsAccessibilityStatus {
            recorder.append(.accessibilityPrompt)
            return status
        }
    }

    private final class ProviderManager: SettingsProviderManaging, @unchecked Sendable {
        let id: ProviderConfigurationID
        let secondID = ProviderConfigurationID()
        let recorder: Recorder
        var applications: Set<ApplicationIdentity> = []
        var updatedIDs: [ProviderConfigurationID] = []
        var credentialChanges: [SettingsCredentialDisposition] = []
        var createHadCredential: [Bool] = []
        var failNextMutation = false
        var failApplicationWrite = false

        var descriptor: SettingsProviderDescriptor {
            SettingsProviderDescriptor(
                id: id,
                protocolKind: .openAICompatible,
                privacyClass: .unresolvedOrChanged,
                hasCredential: true
            )
        }

        init(id: ProviderConfigurationID, recorder: Recorder) {
            self.id = id
            self.recorder = recorder
        }

        func descriptors() async throws -> [SettingsProviderDescriptor] {
            [descriptor, SettingsProviderDescriptor(
                id: secondID,
                protocolKind: .openAICompatible,
                privacyClass: .unresolvedOrChanged,
                hasCredential: false
            )]
        }

        func configuration(_ id: ProviderConfigurationID) async throws -> SettingsProviderDetails {
            SettingsProviderDetails(
                id: id,
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://example.invalid/v1")!,
                model: "synthetic-model",
                privacyClass: .cloud,
                hasCredential: true
            )
        }

        func create(
            _ draft: SettingsProviderDraft,
            credential: consuming SensitiveCredentialInput?
        ) async throws -> SettingsProviderDescriptor {
            recorder.append(.vaultCreate)
            switch consume credential {
            case .some: createHadCredential.append(true)
            case .none: createHadCredential.append(false)
            }
            if failNextMutation {
                failNextMutation = false
                throw SanitizedFailure.credentialStoreUnavailable
            }
            return descriptor
        }

        func update(
            _ id: ProviderConfigurationID,
            draft: SettingsProviderDraft,
            credential: consuming ProviderCredentialChange
        ) async throws -> SettingsProviderDescriptor {
            recorder.append(.vaultUpdate)
            updatedIDs.append(id)
            switch consume credential {
            case .preserve: credentialChanges.append(.preserve)
            case .remove: credentialChanges.append(.remove)
            case .replace: credentialChanges.append(.replace)
            }
            if failNextMutation {
                failNextMutation = false
                throw SanitizedFailure.credentialStoreUnavailable
            }
            applications = []
            return descriptor
        }

        func automaticApplications(
            for id: ProviderConfigurationID
        ) async throws -> Set<ApplicationIdentity> {
            recorder.append(.vaultApplicationsRead)
            return applications
        }

        func setAutomaticApplications(
            _ applications: Set<ApplicationIdentity>,
            for id: ProviderConfigurationID
        ) async throws {
            recorder.append(.vaultApplicationsWrite(applications))
            if failApplicationWrite { throw SanitizedFailure.preferencesUnrecoverable }
            self.applications = applications
        }

        func delete(_ id: ProviderConfigurationID) async throws {
            recorder.append(.vaultDelete)
            recorder.append(.authorizationDelete)
        }
    }

    private final class Inspector: SettingsProviderInspecting, @unchecked Sendable {
        let recorder: Recorder
        var protocolKinds: [ProviderConfigurationID: ProviderProtocolKind] = [:]
        var chatRequestCount = 0
        init(recorder: Recorder) { self.recorder = recorder }

        func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
            recorder.append(.resolve)
            recorder.append(.getTags)
            return ["synthetic-model"]
        }

        func testConnection(for id: ProviderConfigurationID) async throws {
            recorder.append(.resolve)
            if protocolKinds[id] == .ollamaNative {
                recorder.append(.getTags)
            } else {
                recorder.append(.tcpTLS)
            }
        }
    }

    private actor DelayedInspector: SettingsProviderInspecting {
        let slowID: ProviderConfigurationID
        private var slowStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var slowContinuation: CheckedContinuation<[String], Never>?

        init(slowID: ProviderConfigurationID) { self.slowID = slowID }

        func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
            guard id == slowID else { return ["model-b"] }
            return await withCheckedContinuation { continuation in
                slowContinuation = continuation
                slowStarted = true
                let waiters = startWaiters
                startWaiters = []
                waiters.forEach { $0.resume() }
            }
        }

        func testConnection(for id: ProviderConfigurationID) async throws {}

        func waitUntilSlowRequestStarts() async {
            if slowStarted { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resumeSlowRequest() {
            slowContinuation?.resume(returning: ["model-a"])
            slowContinuation = nil
        }
    }

    private final class Confirmation: SettingsProviderConfirming, @unchecked Sendable {
        let recorder: Recorder
        var changedOnConfirm = false
        init(recorder: Recorder) { self.recorder = recorder }

        func prepare(
            for id: ProviderConfigurationID,
            protocolKind: ProviderProtocolKind
        ) async throws -> SettingsConfirmationPreview {
            recorder.append(.resolve)
            return SettingsConfirmationPreview(
                token: UUID(),
                configurationID: id,
                protocolKind: protocolKind,
                privacyClass: .cloud
            )
        }

        func confirm(_ preview: SettingsConfirmationPreview) async throws {
            if changedOnConfirm { throw SanitizedFailure.destinationReconfirmationRequired }
            recorder.append(.confirm)
            recorder.append(.authorizationDelete)
        }
    }

    private actor Monitor: SelectionTriggerMonitoring {
        struct Configuration: Equatable, Sendable {
            let mouse: Bool
            let keyboard: Bool
        }
        private(set) var configurations: [Configuration] = []
        func start(mouseEnabled: Bool, keyboardEnabled: Bool) async throws {
            configurations.append(Configuration(mouse: mouseEnabled, keyboard: keyboardEnabled))
        }
        func stop() async {}
    }

    @MainActor
    private struct AccessibilityClient: SettingsAccessibilityClient {
        func status() -> SettingsAccessibilityStatus { .denied }
        func request() -> SettingsAccessibilityStatus { .denied }
        func openSystemSettings() {}
    }
}

private actor SelectionPreferences: PreferencesStore {
    private var value: PreferencesSnapshot
    init(value: PreferencesSnapshot) { self.value = value }
    func snapshot() async throws -> PreferencesSnapshot { value }
    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        try transform(&value)
    }
}

@MainActor
private final class CaptureLifecycleRecorder: CapturePreferenceLifecycleControlling {
    struct Snapshot {
        let onboarding: Bool
        let automatic: Bool
        let mouse: Bool
        let keyboard: Bool
    }
    private(set) var snapshots: [Snapshot] = []
    func applyCapturePreferences(
        onboardingCompleted: Bool,
        automaticCaptureEnabled: Bool,
        mouseSelectionEnabled: Bool,
        keyboardSelectionEnabled: Bool
    ) async throws {
        snapshots.append(.init(
            onboarding: onboardingCompleted,
            automatic: automaticCaptureEnabled,
            mouse: mouseSelectionEnabled,
            keyboard: keyboardSelectionEnabled
        ))
    }
}
