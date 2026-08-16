import Foundation
import ModelProviders
import Observation
import PrivacyStorage
import SelectionCapture
import ServiceManagement
import SharedSupport
import TranslationCore

private enum PreferencePersistenceOutcome: Equatable {
    case committed
    case notCommitted
    case committedProjectionUnavailable
    case outcomeUnknown

    var didCommit: Bool {
        self == .committed || self == .committedProjectionUnavailable
    }
}

@MainActor
final class CompositionRuntimeOperationOwner {
    private var isAccepting = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func submit(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard isAccepting else { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.finished(id)
        }
        tasks[id] = task
        return task
    }

    func retireAndDrain() async {
        isAccepting = false
        let active = Array(tasks.values)
        active.forEach { $0.cancel() }
        guard !tasks.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
        guard tasks.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class SettingsEffectGate {
    private var isAccepting = true
    private var isHeld = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    var isRetired: Bool { !isAccepting }

    func acquire() async -> Bool {
        guard isAccepting else { return false }
        if !isHeld {
            isHeld = true
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if isAccepting, !waiters.isEmpty {
            waiters.removeFirst().resume(returning: true)
        } else {
            isHeld = false
            let rejected = waiters
            waiters.removeAll()
            rejected.forEach { $0.resume(returning: false) }
            let drained = drainWaiters
            drainWaiters.removeAll()
            drained.forEach { $0.resume() }
        }
    }

    func retireAndDrain() async {
        isAccepting = false
        let rejected = waiters
        waiters.removeAll()
        rejected.forEach { $0.resume(returning: false) }
        guard isHeld else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
}

enum SettingsSafeError: CaseIterable, Equatable, Sendable {
    case persistenceFailed
    case shortcutUnavailable
    case launchAtLoginUnavailable
    case selectionEffectUnavailable
    case invalidValue
    case providerUnavailable
    case confirmationChanged
    case promptUnavailable
    case promptReplacementRequired
    case historyUnavailable
    case diagnosticsUnavailable
    case resetIncomplete
    case runtimeRefreshUnavailable
}

enum SettingsAccessibilityStatus: String, Equatable, Sendable {
    case unknown
    case granted
    case denied
}

enum SettingsCredentialDisposition: String, CaseIterable, Identifiable, Sendable {
    case preserve
    case remove
    case replace

    var id: String { rawValue }
}

struct SettingsProviderDescriptor: Identifiable, Equatable, Sendable {
    let id: ProviderConfigurationID
    let protocolKind: ProviderProtocolKind
    let privacyClass: DestinationPrivacyClass
    let hasCredential: Bool
}

struct SettingsProviderDetails: Equatable, Sendable {
    let id: ProviderConfigurationID
    let protocolKind: ProviderProtocolKind
    let endpoint: URL
    let model: String
    let privacyClass: DestinationPrivacyClass
    let hasCredential: Bool
}

struct SettingsProviderDraft: Equatable, Sendable {
    var protocolKind: ProviderProtocolKind
    var endpoint: URL
    var model: String
}

struct SettingsConfirmationPreview: Equatable, Sendable {
    let token: UUID
    let configurationID: ProviderConfigurationID
    let protocolKind: ProviderProtocolKind
    let privacyClass: DestinationPrivacyClass
}

@MainActor
protocol SettingsLaunchAtLoginControlling: Sendable {
    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
protocol SettingsSelectionControlling: Sendable {
    func setAutomaticEnabled(_ enabled: Bool) async throws
    func setMouseEnabled(_ enabled: Bool) async throws
    func setKeyboardEnabled(_ enabled: Bool) async throws
    func accessibilityStatus() -> SettingsAccessibilityStatus
    func openAccessibilitySettings()
    func requestAccessibility() -> SettingsAccessibilityStatus
}

extension SettingsSelectionControlling {
    func setAutomaticEnabled(_ enabled: Bool) async throws {}
}

protocol SettingsProviderManaging: Sendable {
    func descriptors() async throws -> [SettingsProviderDescriptor]
    func configuration(_ id: ProviderConfigurationID) async throws -> SettingsProviderDetails
    func create(
        _ draft: SettingsProviderDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SettingsProviderDescriptor
    func update(
        _ id: ProviderConfigurationID,
        draft: SettingsProviderDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SettingsProviderDescriptor
    func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity>
    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws
    func delete(_ id: ProviderConfigurationID) async throws
}

protocol SettingsProviderInspecting: Sendable {
    func discoverModels(for id: ProviderConfigurationID) async throws -> [String]
    func testConnection(for id: ProviderConfigurationID) async throws
}

protocol SettingsProviderConfirming: Sendable {
    func prepare(
        for id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind
    ) async throws -> SettingsConfirmationPreview
    func confirm(_ preview: SettingsConfirmationPreview) async throws
}

struct ProductionSettingsProviderManager: SettingsProviderManaging {
    let management: any ProviderManagement

    func descriptors() async throws -> [SettingsProviderDescriptor] {
        try await management.descriptors().map(Self.map)
    }

    func configuration(_ id: ProviderConfigurationID) async throws -> SettingsProviderDetails {
        let details = try await management.configuration(id)
        return SettingsProviderDetails(
            id: details.id,
            protocolKind: details.protocolKind,
            endpoint: details.endpoint,
            model: details.model,
            privacyClass: details.privacyClass,
            hasCredential: details.hasCredential
        )
    }

    func create(
        _ draft: SettingsProviderDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SettingsProviderDescriptor {
        let descriptor = try await management.create(
            ProviderConfigurationDraft(
                protocolKind: draft.protocolKind,
                endpoint: draft.endpoint,
                model: draft.model
            ),
            credential: consume credential
        )
        return Self.map(descriptor)
    }

    func update(
        _ id: ProviderConfigurationID,
        draft: SettingsProviderDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SettingsProviderDescriptor {
        let descriptor = try await management.update(
            id,
            draft: ProviderConfigurationDraft(
                protocolKind: draft.protocolKind,
                endpoint: draft.endpoint,
                model: draft.model
            ),
            credential: consume credential
        )
        return Self.map(descriptor)
    }

    func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> {
        try await management.automaticApplications(for: id)
    }

    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {
        try await management.setAutomaticApplications(applications, for: id)
    }

    func delete(_ id: ProviderConfigurationID) async throws {
        try await management.delete(id)
    }

    static func map(_ descriptor: SanitizedProviderDescriptor) -> SettingsProviderDescriptor {
        SettingsProviderDescriptor(
            id: descriptor.id,
            protocolKind: descriptor.protocolKind,
            privacyClass: descriptor.privacyClass,
            hasCredential: descriptor.hasCredential
        )
    }
}

struct ProductionSettingsProviderInspector: SettingsProviderInspecting {
    let inspection: any ProviderInspection

    func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
        try await inspection.discoverModels(for: id)
    }

    func testConnection(for id: ProviderConfigurationID) async throws {
        try await inspection.testConnection(for: id)
    }
}

actor ProductionSettingsProviderConfirmation: SettingsProviderConfirming {
    private let service: any ProviderConfirmationService
    private var challenges: [UUID: ProviderConfirmationChallenge] = [:]

    init(service: any ProviderConfirmationService) {
        self.service = service
    }

    func prepare(
        for id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind
    ) async throws -> SettingsConfirmationPreview {
        let challenge = try await service.prepareConfirmation(for: id)
        let token = UUID()
        challenges[token] = challenge
        return SettingsConfirmationPreview(
            token: token,
            configurationID: id,
            protocolKind: protocolKind,
            privacyClass: challenge.proposedClass
        )
    }

    func confirm(_ preview: SettingsConfirmationPreview) async throws {
        guard let challenge = challenges.removeValue(forKey: preview.token),
              challenge.configurationID == preview.configurationID else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        _ = try await service.confirm(challenge)
    }
}

@MainActor
struct SystemSettingsLaunchAtLoginController: SettingsLaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var snapshot: PreferencesSnapshot
    private(set) var providers: [SettingsProviderDescriptor] = []
    private(set) var selectedProvider: SettingsProviderDetails?
    private(set) var discoveredModels: [String] = []
    private(set) var confirmationPreview: SettingsConfirmationPreview?
    private(set) var automaticApplications: Set<ApplicationIdentity> = []
    private(set) var safeError: SettingsSafeError?
    private(set) var shortcutError: SettingsSafeError?
    private(set) var shortcutCandidate: ShortcutDescriptor
    private(set) var credentialFieldIsEmpty = true
    private(set) var accessibilityStatus: SettingsAccessibilityStatus
    private(set) var automaticApplicationsProviderID: ProviderConfigurationID?
    private(set) var activeProviderID: ProviderConfigurationID?
    private(set) var builtInPrompts: [PromptPresetDescriptor] = []
    private(set) var customPrompts: [CustomPreset] = []
    private(set) var promptDraft: CustomPreset?
    private(set) var promptValidationFailure: PromptPresetFailure?
    private(set) var promptPreview: PromptPresetPreview?
    private(set) var promptReplacementRequiredID: PresetID?
    private(set) var promptMutationInFlight = false
    private(set) var historyRecords: [SettingsHistoryRecord] = []
    private(set) var historyState: SettingsHistoryState = .idle
    private(set) var historyOpenInFlight = false
    private(set) var historyMutationInFlight = false
    private(set) var diagnosticsInFlight = false
    private(set) var diagnosticsOutcome: DiagnosticExportOutcome?
    private(set) var resetInFlight = false
    private(set) var resetReport: ResetReport?

    private let preferences: any PreferencesStore
    private let shortcut: ShortcutSettingsModel
    private let launchAtLogin: any SettingsLaunchAtLoginControlling
    private let selection: any SettingsSelectionControlling
    private let provider: any SettingsProviderManaging
    private let inspection: any SettingsProviderInspecting
    private let confirmation: any SettingsProviderConfirming
    private let promptStore: any PromptPresetStore
    private let history: any SettingsHistoryManaging
    private let diagnostics: any SettingsDiagnosticsStarting
    private let reset: any SettingsResetting
    private let runtimeRefresh: any SettingsRuntimeRefreshing
    private let runtimeOperations: CompositionRuntimeOperationOwner
    private let snapshotChanged:
        (@MainActor @Sendable (PreferencesSnapshot) async -> Void)?
    private let shortcutEffectGate = SettingsEffectGate()
    private let launchEffectGate = SettingsEffectGate()
    private var credentialInput = ""
    private var providerStateGeneration: UInt = 0
    private var diagnosticsHasStarted = false
    private var resetHasStarted = false
    private var promptDraftGeneration: UInt = 0
    private var promptPreviewGeneration: UInt = 0
    private var promptCatalogGeneration: UInt = 0
    private var historyContentGeneration: UInt = 0

    init(
        initialSnapshot: PreferencesSnapshot,
        preferences: any PreferencesStore,
        shortcut: ShortcutSettingsModel,
        launchAtLogin: any SettingsLaunchAtLoginControlling,
        selection: any SettingsSelectionControlling,
        provider: any SettingsProviderManaging,
        inspection: any SettingsProviderInspecting,
        confirmation: any SettingsProviderConfirming,
        promptStore: any PromptPresetStore = UnavailablePromptPresetStore(),
        history: any SettingsHistoryManaging = UnavailableSettingsHistory(),
        diagnostics: any SettingsDiagnosticsStarting = UnavailableSettingsDiagnostics(),
        reset: any SettingsResetting = UnavailableSettingsReset(),
        runtimeRefresh: any SettingsRuntimeRefreshing = NoopSettingsRuntimeRefresh(),
        runtimeOperations: CompositionRuntimeOperationOwner = .init(),
        initialAccessibilityStatus: SettingsAccessibilityStatus = .unknown,
        initialProviders: [SettingsProviderDescriptor] = [],
        initialResetReport: ResetReport? = nil,
        snapshotChanged:
            (@MainActor @Sendable (PreferencesSnapshot) async -> Void)? = nil
    ) {
        snapshot = initialSnapshot
        self.preferences = preferences
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
        self.selection = selection
        self.provider = provider
        self.inspection = inspection
        self.confirmation = confirmation
        self.promptStore = promptStore
        self.history = history
        self.diagnostics = diagnostics
        self.reset = reset
        self.runtimeRefresh = runtimeRefresh
        self.runtimeOperations = runtimeOperations
        self.snapshotChanged = snapshotChanged
        accessibilityStatus = initialAccessibilityStatus
        providers = initialProviders
        shortcutCandidate = initialSnapshot.shortcut
        resetReport = initialResetReport
        AppUILocaleState.shared.set(initialSnapshot.uiLanguage)
    }

    var shortcutLabel: String { shortcut.currentLabel }
    var shortcutRegistrationState: ShortcutRegistrationState { shortcut.state }
    var shortcutSafeNextActionKey: String? { shortcut.safeNextActionKey }
    var availablePromptIDs: [PresetID] {
        builtInPrompts.map(\.id) + customPrompts.map(\.id)
    }
    var canSavePromptDraft: Bool {
        promptDraft != nil && promptValidationFailure == nil && !promptMutationInFlight
    }

    var uiLocale: Locale {
        snapshot.uiLanguage.locale
    }

    func performOwned(
        _ operation: @escaping @MainActor @Sendable (SettingsViewModel) async -> Void
    ) {
        runtimeOperations.submit { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    func performOwnedAndWait(
        _ operation: @escaping @MainActor @Sendable (SettingsViewModel) async -> Void
    ) async {
        guard let task = runtimeOperations.submit({ [weak self] in
            guard let self else { return }
            await operation(self)
        }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func setCredentialInput(_ value: String) {
        credentialInput = value
        credentialFieldIsEmpty = value.isEmpty
    }

    func recordShortcutCandidate(_ descriptor: ShortcutDescriptor) {
        shortcutCandidate = descriptor
    }

    func setUILanguage(_ value: ApplicationLanguage) async {
        if await persist({ $0.uiLanguage = value }) == .committed {
            AppUILocaleState.shared.set(value)
        }
    }

    func setTargetLanguage(_ value: LanguageChoice) async {
        await persist { $0.defaultTargetLanguage = value }
    }

    func setDefaultPreset(_ value: PresetID) async {
        guard !promptMutationInFlight else { return }
        promptMutationInFlight = true
        defer { promptMutationInFlight = false }
        await persist { $0.defaultPresetID = value }
    }

    func setDefaultProvider(_ value: ProviderConfigurationID?) async {
        await persist { $0.defaultProviderID = value }
    }

    func setAutomaticCaptureEnabled(_ enabled: Bool) async {
        let previous = snapshot.automaticCaptureEnabled
        do {
            try await selection.setAutomaticEnabled(enabled)
        } catch {
            safeError = .selectionEffectUnavailable
            return
        }
        switch await persist({ $0.automaticCaptureEnabled = enabled }) {
        case .committed:
            break
        case .notCommitted:
            try? await selection.setAutomaticEnabled(previous)
        case .committedProjectionUnavailable, .outcomeUnknown:
            if enabled { try? await selection.setAutomaticEnabled(false) }
        }
    }

    func setShortcut(_ descriptor: ShortcutDescriptor) async {
        guard await shortcutEffectGate.acquire() else { return }
        defer { shortcutEffectGate.release() }
        shortcutCandidate = descriptor
        let previous = shortcut.currentDescriptor
        await shortcut.register(descriptor)
        guard shortcut.state == .registered,
              shortcut.currentDescriptor == descriptor else {
            safeError = .shortcutUnavailable
            shortcutError = .shortcutUnavailable
            shortcutCandidate = snapshot.shortcut
            await notifyRuntimeProjection()
            return
        }
        switch await persist(
            { $0.shortcut = descriptor },
            reconcileUnknown: { [weak self] in
                await self?.reconcileUnknownShortcutOutcome()
            }
        ) {
        case .notCommitted:
            shortcutError = .persistenceFailed
            if let previous { await shortcut.register(previous) }
            shortcutCandidate = snapshot.shortcut
            await notifyRuntimeProjection()
            return
        case .committedProjectionUnavailable, .outcomeUnknown:
            shortcutError = .persistenceFailed
            return
        case .committed:
            break
        }
        shortcutError = nil
        shortcutCandidate = descriptor
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard await launchEffectGate.acquire() else { return }
        defer { launchEffectGate.release() }
        let previous = snapshot.launchAtLogin
        do {
            try await launchAtLogin.setEnabled(enabled)
        } catch {
            safeError = .launchAtLoginUnavailable
            return
        }
        switch await persist(
            { $0.launchAtLogin = enabled },
            reconcileUnknown: { [weak self] in
                await self?.reconcileUnknownLaunchOutcome()
            }
        ) {
        case .notCommitted:
            try? await launchAtLogin.setEnabled(previous)
            return
        case .committedProjectionUnavailable, .outcomeUnknown:
            return
        case .committed:
            break
        }
    }

    func setGeneralApplications(_ applications: Set<ApplicationIdentity>) async {
        await persist { $0.generalAutomaticApplications = applications }
    }

    func addGeneralApplication(bundleIdentifier: String, displayName: String) async {
        let bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty, !displayName.isEmpty else {
            safeError = .invalidValue
            return
        }
        var applications = snapshot.generalAutomaticApplications
        applications = applications.filter { $0.bundleIdentifier != bundleIdentifier }
        applications.insert(ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        ))
        await setGeneralApplications(applications)
    }

    func removeGeneralApplication(_ application: ApplicationIdentity) async {
        var applications = snapshot.generalAutomaticApplications
        applications.remove(application)
        await setGeneralApplications(applications)
    }

    func setMouseSelectionEnabled(_ enabled: Bool) async {
        await setSelectionEffect(
            enabled,
            previous: snapshot.mouseSelectionEnabled,
            effect: { try await self.selection.setMouseEnabled($0) },
            mutation: { $0.mouseSelectionEnabled = $1 }
        )
    }

    func setKeyboardSelectionEnabled(_ enabled: Bool) async {
        await setSelectionEffect(
            enabled,
            previous: snapshot.keyboardSelectionEnabled,
            effect: { try await self.selection.setKeyboardEnabled($0) },
            mutation: { $0.keyboardSelectionEnabled = $1 }
        )
    }

    func setClipboardFallbackEnabled(_ enabled: Bool, disclosureVisible: Bool) async {
        guard !enabled || disclosureVisible else {
            safeError = .invalidValue
            return
        }
        await persist { $0.clipboardFallbackEnabled = enabled }
    }

    func setSelectionDebounceMilliseconds(_ value: Int) async {
        guard (100...2_000).contains(value) else {
            safeError = .invalidValue
            return
        }
        await persist { $0.selectionDebounceMilliseconds = value }
    }

    func setSelectionCharacterLimit(_ value: Int) async {
        guard (1...20_000).contains(value) else {
            safeError = .invalidValue
            return
        }
        await persist { $0.selectionCharacterLimit = value }
    }

    func refreshAccessibilityStatus() {
        accessibilityStatus = selection.accessibilityStatus()
    }

    func openAccessibilitySettings() { selection.openAccessibilitySettings() }

    func requestAccessibility() {
        accessibilityStatus = selection.requestAccessibility()
    }

    func setTimeouts(connection: Int, firstToken: Int, streamIdle: Int) async {
        guard (1...60).contains(connection),
              (5...600).contains(firstToken),
              (5...120).contains(streamIdle) else {
            safeError = .invalidValue
            return
        }
        await persist {
            $0.connectionTimeoutSeconds = connection
            $0.firstTokenTimeoutSeconds = firstToken
            $0.streamIdleTimeoutSeconds = streamIdle
        }
    }

    func loadPromptPresets() async {
        promptCatalogGeneration &+= 1
        let generation = promptCatalogGeneration
        let builtIns = await promptStore.builtIns()
        do {
            let custom = try await promptStore.customPresets()
            guard generation == promptCatalogGeneration else { return }
            builtInPrompts = builtIns
            customPrompts = custom
            safeError = nil
            await notifyRuntimeProjection()
        } catch {
            guard generation == promptCatalogGeneration else { return }
            builtInPrompts = builtIns
            customPrompts = []
            safeError = .promptUnavailable
        }
    }

    func beginNewPrompt() {
        promptDraftGeneration &+= 1
        promptDraft = CustomPreset(
            id: .custom(),
            name: "",
            explanation: "",
            template: "",
            targetLanguage: .automatic,
            action: .translate
        )
        promptValidationFailure = .emptyName
        promptPreview = nil
    }

    func editCustomPrompt(_ preset: CustomPreset) {
        promptDraftGeneration &+= 1
        promptDraft = preset
        promptValidationFailure = nil
        promptPreview = nil
    }

    func duplicateBuiltInPrompt(_ id: PresetID) async {
        promptDraftGeneration &+= 1
        let generation = promptDraftGeneration
        do {
            let duplicate = try await promptStore.duplicateBuiltIn(id)
            guard generation == promptDraftGeneration else { return }
            promptDraft = duplicate
            _ = try await promptStore.validate(duplicate)
            guard generation == promptDraftGeneration else { return }
            promptValidationFailure = nil
            promptPreview = nil
            safeError = nil
        } catch let failure as PromptPresetFailure {
            guard generation == promptDraftGeneration else { return }
            promptDraft = nil
            promptValidationFailure = failure
            safeError = .promptUnavailable
        } catch {
            guard generation == promptDraftGeneration else { return }
            promptDraft = nil
            safeError = .promptUnavailable
        }
    }

    func updatePromptDraft(_ preset: CustomPreset) async {
        promptDraftGeneration &+= 1
        let generation = promptDraftGeneration
        promptDraft = preset
        do {
            _ = try await promptStore.validate(preset)
            guard generation == promptDraftGeneration else { return }
            promptValidationFailure = nil
            safeError = nil
        } catch let failure as PromptPresetFailure {
            guard generation == promptDraftGeneration else { return }
            promptValidationFailure = failure
        } catch {
            guard generation == promptDraftGeneration else { return }
            promptValidationFailure = nil
            safeError = .promptUnavailable
        }
    }

    func savePromptDraft() async {
        guard let draft = promptDraft, !promptMutationInFlight else { return }
        promptMutationInFlight = true
        defer { promptMutationInFlight = false }
        let generation = promptDraftGeneration
        do {
            _ = try await promptStore.validate(draft)
            guard generation == promptDraftGeneration else { return }
            try await promptStore.save(draft)
            if generation == promptDraftGeneration {
                promptDraftGeneration &+= 1
                promptDraft = nil
                promptValidationFailure = nil
            }
            await loadPromptPresets()
        } catch let failure as PromptPresetFailure {
            promptValidationFailure = failure
        } catch {
            safeError = .promptUnavailable
        }
    }

    func previewPrompt(_ id: PresetID) async {
        promptPreviewGeneration &+= 1
        let generation = promptPreviewGeneration
        do {
            let preview = try await promptStore.preview(
                id,
                sourceLanguage: .automatic,
                targetLanguage: snapshot.defaultTargetLanguage
            )
            guard generation == promptPreviewGeneration else { return }
            promptPreview = preview
            safeError = nil
        } catch {
            guard generation == promptPreviewGeneration else { return }
            promptPreview = nil
            safeError = .promptUnavailable
        }
    }

    func deletePrompt(
        _ id: PresetID,
        replacement: PresetID? = nil
    ) async {
        guard !promptMutationInFlight else { return }
        promptMutationInFlight = true
        defer { promptMutationInFlight = false }
        let previousDefault = snapshot.defaultPresetID
        if previousDefault == id {
            guard let replacement,
                  replacement != id,
                  availablePromptIDs.contains(replacement) else {
                promptReplacementRequiredID = id
                safeError = .promptReplacementRequired
                return
            }
            guard await persist({ $0.defaultPresetID = replacement }).didCommit else {
                return
            }
        }
        do {
            try await promptStore.delete(id)
            customPrompts.removeAll { $0.id == id }
            promptReplacementRequiredID = nil
            safeError = nil
            await notifyRuntimeProjection()
        } catch {
            if previousDefault == id {
                _ = await persist { $0.defaultPresetID = previousDefault }
            }
            safeError = .promptUnavailable
        }
    }

    func setHistoryEnabled(_ enabled: Bool) async {
        await persist { $0.historyEnabled = enabled }
    }

    func setHistoryRetentionDays(_ days: Int) async {
        guard (1...365).contains(days) else {
            safeError = .invalidValue
            return
        }
        await persist { $0.historyRetentionDays = days }
    }

    func setHistoryMaximumCount(_ count: Int) async {
        guard (1...10_000).contains(count) else {
            safeError = .invalidValue
            return
        }
        await persist { $0.historyMaximumCount = count }
    }

    func setHistoryExcludedApplications(
        _ applications: Set<ApplicationIdentity>
    ) async {
        await persist { $0.historyExcludedApplications = applications }
    }

    func openHistory() async {
        guard !historyOpenInFlight else { return }
        historyOpenInFlight = true
        defer { historyOpenInFlight = false }
        historyContentGeneration &+= 1
        let generation = historyContentGeneration
        do {
            try await history.performMaintenance()
            guard generation == historyContentGeneration else { return }
            let records = try await history.search(.all)
            guard generation == historyContentGeneration else { return }
            historyRecords = records
            historyState = .loaded
            safeError = nil
        } catch {
            guard generation == historyContentGeneration else { return }
            handleHistoryFailure(error)
        }
    }

    func searchHistory(_ query: String) async {
        guard historyState == .loaded,
              !historyOpenInFlight,
              !historyMutationInFlight else { return }
        historyContentGeneration &+= 1
        let generation = historyContentGeneration
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let records = try await history.search(
                trimmed.isEmpty ? .all : .contains(trimmed)
            )
            guard generation == historyContentGeneration else { return }
            historyRecords = records
            historyState = .loaded
            safeError = nil
        } catch {
            guard generation == historyContentGeneration else { return }
            handleHistoryFailure(error)
        }
    }

    func deleteHistoryRecord(_ id: TranslationRecordID) async {
        guard historyState == .loaded, !historyMutationInFlight else { return }
        historyMutationInFlight = true
        defer { historyMutationInFlight = false }
        historyContentGeneration &+= 1
        let generation = historyContentGeneration
        do {
            try await history.delete(id)
            guard generation == historyContentGeneration else { return }
            historyRecords.removeAll { $0.id == id }
            safeError = nil
        } catch {
            guard generation == historyContentGeneration else { return }
            handleHistoryFailure(error)
        }
    }

    func clearHistory() async {
        guard historyState == .loaded, !historyMutationInFlight else { return }
        historyMutationInFlight = true
        defer { historyMutationInFlight = false }
        historyContentGeneration &+= 1
        let generation = historyContentGeneration
        do {
            try await history.clearAll()
            guard generation == historyContentGeneration else { return }
            historyRecords = []
            historyState = .loaded
            safeError = nil
        } catch {
            guard generation == historyContentGeneration else { return }
            handleHistoryFailure(error)
        }
    }

    func deleteUnrecoverableHistoryAndRestart() async {
        guard historyState == .unrecoverable, !historyMutationInFlight else { return }
        historyMutationInFlight = true
        defer { historyMutationInFlight = false }
        historyContentGeneration &+= 1
        let generation = historyContentGeneration
        do {
            try await history.clearAll()
            guard generation == historyContentGeneration else { return }
            historyRecords = []
            historyState = .deleteAndRestartCompleted
            safeError = nil
        } catch {
            guard generation == historyContentGeneration else { return }
            historyState = .unrecoverable
            safeError = .historyUnavailable
        }
    }

    func clearHistoryViewCache() {
        historyContentGeneration &+= 1
        historyRecords = []
        if historyState == .loaded { historyState = .idle }
    }

    func startDiagnostics() async {
        guard !diagnosticsHasStarted, !diagnosticsInFlight else { return }
        diagnosticsHasStarted = true
        diagnosticsInFlight = true
        defer { diagnosticsInFlight = false }
        diagnosticsOutcome = await diagnostics.start()
        safeError = diagnosticsOutcome == .failed ? .diagnosticsUnavailable : nil
    }

    func confirmReset() async {
        guard !resetHasStarted, !resetInFlight else { return }
        resetHasStarted = true
        resetInFlight = true
        defer { resetInFlight = false }
        promptCatalogGeneration &+= 1
        promptDraftGeneration &+= 1
        promptPreviewGeneration &+= 1
        await retireExternalEffects()
        let report: ResetReport
        var replacementFailed = false
        do {
            report = try await runtimeRefresh.resetAndReplace(using: reset)
            safeError = nil
        } catch let failure as SettingsRuntimeRefreshFailure {
            report = failure.report
            replacementFailed = true
        } catch {
            safeError = .runtimeRefreshUnavailable
            return
        }
        resetReport = report
        let failures = report.failedStages
        if !failures.contains(.deleteHistoryStoreAndKey) {
            clearHistoryViewCache()
            historyState = .idle
        }
        if !failures.contains(.deletePrivatePresetStoreAndKey) {
            customPrompts = []
        }
        if !failures.contains(.deleteProviderVault) {
            providers = []
            _ = beginProviderState(for: nil)
        }
        promptDraft = nil
        promptPreview = nil
        if replacementFailed {
            safeError = .runtimeRefreshUnavailable
        } else if !report.failedStages.isEmpty {
            safeError = .resetIncomplete
        }
    }

    func reloadProviders() async {
        do {
            providers = try await provider.descriptors()
            safeError = nil
            await notifyRuntimeProjection()
        } catch {
            safeError = .providerUnavailable
        }
    }

    func selectProvider(_ id: ProviderConfigurationID) async {
        let generation = beginProviderState(for: id)
        do {
            let details = try await provider.configuration(id)
            guard isCurrentProviderState(generation, id: id) else { return }
            selectedProvider = details
            safeError = nil
        } catch {
            guard isCurrentProviderState(generation, id: id) else { return }
            safeError = .providerUnavailable
        }
    }

    func discoverModels(for id: ProviderConfigurationID) async {
        let generation = providerStateGeneration
        guard activeProviderID == id else { return }
        do {
            let models = try await inspection.discoverModels(for: id)
            guard isCurrentProviderState(generation, id: id) else { return }
            discoveredModels = models
            safeError = nil
        } catch {
            guard isCurrentProviderState(generation, id: id) else { return }
            discoveredModels = []
            safeError = .providerUnavailable
        }
    }

    func saveProvider(
        id: ProviderConfigurationID?,
        draft: SettingsProviderDraft,
        credentialDisposition: SettingsCredentialDisposition
    ) async {
        let requestGeneration = providerStateGeneration
        let requestActiveID = activeProviderID
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            safeError = .invalidValue
            return
        }
        let normalized = SettingsProviderDraft(
            protocolKind: draft.protocolKind,
            endpoint: draft.endpoint,
            model: model
        )
        do {
            let descriptor: SettingsProviderDescriptor
            if let id {
                descriptor = try await updateProvider(
                    id: id,
                    draft: normalized,
                    disposition: credentialDisposition
                )
            } else {
                let input = credentialInput.isEmpty
                    ? nil
                    : SensitiveCredentialInput(credentialInput)
                descriptor = try await provider.create(normalized, credential: consume input)
            }
            credentialInput = ""
            credentialFieldIsEmpty = true
            upsert(descriptor)
            guard providerStateGeneration == requestGeneration,
                  activeProviderID == requestActiveID else { return }
            _ = beginProviderState(for: descriptor.id)
            selectedProvider = SettingsProviderDetails(
                id: descriptor.id,
                protocolKind: descriptor.protocolKind,
                endpoint: normalized.endpoint,
                model: normalized.model,
                privacyClass: descriptor.privacyClass,
                hasCredential: descriptor.hasCredential
            )
            safeError = nil
            await notifyRuntimeProjection()
            if descriptor.privacyClass == .unresolvedOrChanged {
                await prepareConfirmation(for: descriptor)
            }
        } catch {
            guard providerStateGeneration == requestGeneration,
                  activeProviderID == requestActiveID else { return }
            safeError = .providerUnavailable
        }
    }

    func prepareConfirmation(for descriptor: SettingsProviderDescriptor) async {
        let generation = beginProviderState(for: descriptor.id)
        do {
            let details = try await provider.configuration(descriptor.id)
            guard isCurrentProviderState(generation, id: descriptor.id) else { return }
            let preview = try await confirmation.prepare(
                for: descriptor.id,
                protocolKind: descriptor.protocolKind
            )
            guard isCurrentProviderState(generation, id: descriptor.id) else { return }
            selectedProvider = details
            confirmationPreview = preview
            safeError = nil
        } catch {
            guard isCurrentProviderState(generation, id: descriptor.id) else { return }
            confirmationPreview = nil
            safeError = .providerUnavailable
        }
    }

    func confirmDestination() async {
        guard let preview = confirmationPreview,
              selectedProvider?.id == preview.configurationID,
              activeProviderID == preview.configurationID else {
            safeError = .confirmationChanged
            confirmationPreview = nil
            return
        }
        let generation = providerStateGeneration
        do {
            try await confirmation.confirm(preview)
            guard isCurrentProviderState(
                generation,
                id: preview.configurationID
            ) else { return }
            confirmationPreview = nil
            automaticApplications = []
            automaticApplicationsProviderID = nil
            safeError = nil
            await reloadProviders()
        } catch {
            guard isCurrentProviderState(
                generation,
                id: preview.configurationID
            ) else { return }
            confirmationPreview = nil
            safeError = .confirmationChanged
        }
    }

    func testConnection(for id: ProviderConfigurationID) async {
        do {
            try await inspection.testConnection(for: id)
            safeError = nil
        } catch {
            safeError = .providerUnavailable
        }
    }

    func loadAutomaticApplications(for id: ProviderConfigurationID) async {
        let generation = providerStateGeneration
        guard activeProviderID == id else { return }
        do {
            let stored = try await provider.automaticApplications(for: id)
            let ceiling = try await preferences.snapshot().generalAutomaticApplications
            let effective = stored.intersection(ceiling)
            guard isCurrentProviderState(generation, id: id) else { return }
            automaticApplications = effective
            automaticApplicationsProviderID = id
            if effective != stored {
                do {
                    try await provider.setAutomaticApplications(effective, for: id)
                } catch {
                    guard isCurrentProviderState(generation, id: id) else { return }
                    safeError = .providerUnavailable
                    return
                }
            }
            guard isCurrentProviderState(generation, id: id) else { return }
            safeError = nil
        } catch {
            guard isCurrentProviderState(generation, id: id) else { return }
            automaticApplications = []
            safeError = .providerUnavailable
        }
    }

    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async {
        let generation = providerStateGeneration
        guard activeProviderID == id else { return }
        do {
            let ceiling = try await preferences.snapshot().generalAutomaticApplications
            let effective = applications.intersection(ceiling)
            try await provider.setAutomaticApplications(effective, for: id)
            guard isCurrentProviderState(generation, id: id) else { return }
            automaticApplications = effective
            automaticApplicationsProviderID = id
            safeError = nil
        } catch {
            guard isCurrentProviderState(generation, id: id) else { return }
            safeError = .providerUnavailable
        }
    }

    func deleteProvider(_ id: ProviderConfigurationID) async {
        do {
            try await provider.delete(id)
            providers.removeAll { $0.id == id }
            if activeProviderID == id { _ = beginProviderState(for: nil) }
            safeError = nil
            await notifyRuntimeProjection()
        } catch {
            safeError = .providerUnavailable
        }
    }

    private func updateProvider(
        id: ProviderConfigurationID,
        draft: SettingsProviderDraft,
        disposition: SettingsCredentialDisposition
    ) async throws -> SettingsProviderDescriptor {
        switch disposition {
        case .preserve:
            return try await provider.update(id, draft: draft, credential: .preserve)
        case .remove:
            return try await provider.update(id, draft: draft, credential: .remove)
        case .replace:
            guard !credentialInput.isEmpty else { throw SanitizedFailure.invalidProviderConfiguration }
            return try await provider.update(
                id,
                draft: draft,
                credential: .replace(SensitiveCredentialInput(credentialInput))
            )
        }
    }

    @discardableResult
    private func persist(
        _ mutation: @escaping @Sendable (inout PreferencesSnapshot) -> Void,
        reconcileUnknown:
            (@MainActor @Sendable () async -> Void)? = nil
    ) async -> PreferencePersistenceOutcome {
        do {
            try await preferences.update(mutation)
        } catch {
            safeError = .persistenceFailed
            do {
                let authoritative = try await preferences.snapshot()
                var postcondition = authoritative
                mutation(&postcondition)
                snapshot = authoritative
                await snapshotChanged?(authoritative)
                return postcondition == authoritative ? .committed : .notCommitted
            } catch {
                runtimeOperations.submit { @MainActor [weak self] in
                    await Task.yield()
                    if let reconcileUnknown {
                        await reconcileUnknown()
                    } else {
                        await self?.notifyRuntimeProjection()
                    }
                }
                return .outcomeUnknown
            }
        }
        do {
            let stored = try await preferences.snapshot()
            snapshot = stored
            safeError = nil
            await snapshotChanged?(stored)
            return .committed
        } catch {
            safeError = .persistenceFailed
            runtimeOperations.submit { @MainActor [weak self] in
                await Task.yield()
                await self?.notifyRuntimeProjection()
            }
            return .committedProjectionUnavailable
        }
    }

    private func setSelectionEffect(
        _ enabled: Bool,
        previous: Bool,
        effect: @escaping @MainActor (Bool) async throws -> Void,
        mutation: @escaping @Sendable (inout PreferencesSnapshot, Bool) -> Void
    ) async {
        do {
            try await effect(enabled)
        } catch {
            safeError = .selectionEffectUnavailable
            return
        }
        switch await persist({ mutation(&$0, enabled) }) {
        case .committed:
            break
        case .notCommitted:
            try? await effect(previous)
        case .committedProjectionUnavailable, .outcomeUnknown:
            if enabled { try? await effect(false) }
        }
    }

    private func upsert(_ descriptor: SettingsProviderDescriptor) {
        providers.removeAll { $0.id == descriptor.id }
        providers.append(descriptor)
    }

    private func notifyRuntimeProjection() async {
        do {
            let stored = try await preferences.snapshot()
            applyExternalSnapshot(stored)
            await snapshotChanged?(stored)
        } catch {
            safeError = .persistenceFailed
        }
    }

    private func reconcileUnknownLaunchOutcome() async {
        guard await launchEffectGate.acquire() else { return }
        defer { launchEffectGate.release() }
        do {
            let stored = try await preferences.snapshot()
            try await launchAtLogin.setEnabled(stored.launchAtLogin)
            applyExternalSnapshot(stored)
            await snapshotChanged?(stored)
        } catch {
            safeError = .launchAtLoginUnavailable
        }
    }

    private func reconcileUnknownShortcutOutcome() async {
        guard await shortcutEffectGate.acquire() else { return }
        defer { shortcutEffectGate.release() }
        do {
            let stored = try await preferences.snapshot()
            await shortcut.register(stored.shortcut)
            applyExternalSnapshot(stored)
            shortcutCandidate = stored.shortcut
            if shortcut.state == .registered,
               shortcut.currentDescriptor == stored.shortcut {
                shortcutError = nil
            } else {
                shortcutError = .shortcutUnavailable
                safeError = .shortcutUnavailable
            }
            await snapshotChanged?(stored)
        } catch {
            safeError = .persistenceFailed
        }
    }

    func retireExternalEffects() async {
        await runtimeOperations.retireAndDrain()
        await shortcutEffectGate.retireAndDrain()
        await launchEffectGate.retireAndDrain()
    }

    var externalEffectsRetired: Bool {
        shortcutEffectGate.isRetired && launchEffectGate.isRetired
    }

    func applyExternalSnapshot(_ stored: PreferencesSnapshot) {
        snapshot = stored
        shortcutCandidate = stored.shortcut
        AppUILocaleState.shared.set(stored.uiLanguage)
    }

    @discardableResult
    private func beginProviderState(
        for id: ProviderConfigurationID?
    ) -> UInt {
        providerStateGeneration &+= 1
        activeProviderID = id
        selectedProvider = nil
        discoveredModels = []
        confirmationPreview = nil
        automaticApplications = []
        automaticApplicationsProviderID = nil
        return providerStateGeneration
    }

    private func isCurrentProviderState(
        _ generation: UInt,
        id: ProviderConfigurationID
    ) -> Bool {
        providerStateGeneration == generation && activeProviderID == id
    }

    private func handleHistoryFailure(_ error: Error) {
        if error as? SettingsHistoryFailure == .unrecoverable
            || error as? SanitizedFailure == .historyUnrecoverable {
            historyState = .unrecoverable
        } else {
            historyState = .idle
        }
        safeError = .historyUnavailable
    }
}

extension SettingsViewModel {
    static func development() -> SettingsViewModel {
        let snapshot = DevelopmentSettingsPreferences.makeSnapshot()
        let preferences = DevelopmentSettingsPreferences(snapshot: snapshot)
        let shortcut = ShortcutSettingsModel(
            registrar: DevelopmentSettingsShortcutRegistrar(),
            currentDescriptor: snapshot.shortcut
        )
        return SettingsViewModel(
            initialSnapshot: snapshot,
            preferences: preferences,
            shortcut: shortcut,
            launchAtLogin: DevelopmentSettingsLaunchAtLogin(),
            selection: DevelopmentSettingsSelection(),
            provider: DevelopmentSettingsProvider(),
            inspection: DevelopmentSettingsInspection(),
            confirmation: DevelopmentSettingsConfirmation()
        )
    }
}

private actor DevelopmentSettingsPreferences: PreferencesStore {
    private var value: PreferencesSnapshot

    init(snapshot: PreferencesSnapshot) { value = snapshot }

    func snapshot() async throws -> PreferencesSnapshot { value }

    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        try transform(&value)
    }

    nonisolated static func makeSnapshot() -> PreferencesSnapshot {
        let fixture = DevelopmentSettingsPreferencesFixture()
        return try! JSONDecoder().decode(
            PreferencesSnapshot.self,
            from: JSONEncoder().encode(fixture)
        )
    }
}

private struct DevelopmentSettingsPreferencesFixture: Codable {
    var uiLanguage = ApplicationLanguage.english
    var defaultTargetLanguage = LanguageChoice.automatic
    var onboardingCompleted = false
    var automaticCaptureEnabled = false
    var generalAutomaticApplications: Set<ApplicationIdentity> = []
    var mouseSelectionEnabled = false
    var keyboardSelectionEnabled = false
    var clipboardFallbackEnabled = false
    var historyEnabled = false
    var historyRetentionDays = 30
    var historyMaximumCount = 1_000
    var selectionDebounceMilliseconds = 350
    var selectionCharacterLimit = 2_000
    var connectionTimeoutSeconds = 5
    var firstTokenTimeoutSeconds = 120
    var streamIdleTimeoutSeconds = 30
    var launchAtLogin = false
    var shortcut = ShortcutDescriptor.defaultOptionShiftD
    var defaultPresetID = PresetID(rawValue: "accurate-translation")
    var defaultProviderID: ProviderConfigurationID?
    var historyExcludedApplications: Set<ApplicationIdentity> = []
}

private actor DevelopmentSettingsShortcutRegistrar: GlobalShortcutRegistering {
    func register(_ descriptor: ShortcutDescriptor) async throws {
        throw ShortcutRegistrationFailure.unavailable
    }
    func unregister() async {}
}

@MainActor
private struct DevelopmentSettingsLaunchAtLogin: SettingsLaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) async throws {
        throw SanitizedFailure.preferencesUnrecoverable
    }
}

@MainActor
private struct DevelopmentSettingsSelection: SettingsSelectionControlling {
    func setMouseEnabled(_ enabled: Bool) async throws {
        throw SanitizedFailure.preferencesUnrecoverable
    }
    func setKeyboardEnabled(_ enabled: Bool) async throws {
        throw SanitizedFailure.preferencesUnrecoverable
    }
    func accessibilityStatus() -> SettingsAccessibilityStatus { .unknown }
    func openAccessibilitySettings() {}
    func requestAccessibility() -> SettingsAccessibilityStatus { .unknown }
}

private actor DevelopmentSettingsProvider: SettingsProviderManaging {
    func descriptors() async throws -> [SettingsProviderDescriptor] { [] }
    func configuration(_ id: ProviderConfigurationID) async throws -> SettingsProviderDetails {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func create(
        _ draft: SettingsProviderDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SettingsProviderDescriptor {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func update(
        _ id: ProviderConfigurationID,
        draft: SettingsProviderDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SettingsProviderDescriptor {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> { [] }
    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {
        throw SanitizedFailure.invalidProviderConfiguration
    }
    func delete(_ id: ProviderConfigurationID) async throws {
        throw SanitizedFailure.invalidProviderConfiguration
    }
}

private actor DevelopmentSettingsInspection: SettingsProviderInspecting {
    func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
        throw SanitizedFailure.modelUnavailable
    }
    func testConnection(for id: ProviderConfigurationID) async throws {
        throw SanitizedFailure.invalidProviderConfiguration
    }
}

private actor DevelopmentSettingsConfirmation: SettingsProviderConfirming {
    func prepare(
        for id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind
    ) async throws -> SettingsConfirmationPreview {
        throw SanitizedFailure.destinationReconfirmationRequired
    }
    func confirm(_ preview: SettingsConfirmationPreview) async throws {
        throw SanitizedFailure.destinationReconfirmationRequired
    }
}
