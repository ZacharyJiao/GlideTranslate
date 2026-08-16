import PrivacyStorage
import SelectionCapture
import SharedSupport
import TranslationCore
import XCTest

@testable import GlideTranslate

@MainActor
final class PromptSettingsTests: XCTestCase {
    func testPromptActionRowsAreExact() {
        XCTAssertEqual(PromptSettingsContract.rows, [
            .builtInEditAttempt(editable: false),
            .builtInDeleteAttempt(deletable: false),
            .duplicateBuiltIn(newCustomID: true),
            .newCustom(editorOpens: true),
            .invalidCustom(saveEnabled: false),
            .validCustom(saveEnabled: true),
            .preview(sampleSource: .bundledOnly),
            .setDefault(persists: true),
            .deleteCurrentDefault(requiresReplacement: true),
        ])
    }

    func testPromptStoreIsTheOnlyValidationPreviewAndMutationSeam() async {
        let fixture = U8Fixture()
        await fixture.model.loadPromptPresets()
        let builtIn = try! XCTUnwrap(fixture.model.builtInPrompts.first)
        XCTAssertTrue(builtIn.isReadOnly)

        await fixture.model.duplicateBuiltInPrompt(builtIn.id)
        let duplicate = try! XCTUnwrap(fixture.model.promptDraft)
        XCTAssertNotEqual(duplicate.id, builtIn.id)
        XCTAssertTrue(duplicate.id.rawValue.hasPrefix("custom-"))
        XCTAssertTrue(fixture.model.canSavePromptDraft)

        var invalid = duplicate
        invalid.name = ""
        await fixture.model.updatePromptDraft(invalid)
        XCTAssertEqual(fixture.model.promptValidationFailure, .emptyName)
        XCTAssertFalse(fixture.model.canSavePromptDraft)

        await fixture.model.updatePromptDraft(duplicate)
        await fixture.model.savePromptDraft()
        XCTAssertNil(fixture.model.promptDraft)
        XCTAssertEqual(fixture.model.customPrompts.map(\.id), [duplicate.id])

        await fixture.model.previewPrompt(builtIn.id)
        XCTAssertFalse(fixture.model.promptPreview?.instruction.isEmpty ?? true)
        XCTAssertFalse(fixture.model.promptPreview?.sampleUserContent.isEmpty ?? true)
        XCTAssertTrue(fixture.model.promptPreview?.instruction.contains("zh-Hans") == true)
        XCTAssertFalse(
            fixture.model.promptPreview?.instruction.contains("the selected target language")
                ?? true
        )
        let previewIDs = await fixture.prompts.previewIDs()
        XCTAssertEqual(previewIDs, [builtIn.id])

        await fixture.model.setDefaultPreset(duplicate.id)
        XCTAssertEqual(fixture.model.snapshot.defaultPresetID, duplicate.id)
        await fixture.model.deletePrompt(duplicate.id)
        XCTAssertEqual(fixture.model.promptReplacementRequiredID, duplicate.id)
        let deletesBeforeReplacement = await fixture.prompts.deletedIDs()
        XCTAssertEqual(deletesBeforeReplacement, [])

        await fixture.model.deletePrompt(duplicate.id, replacement: builtIn.id)
        XCTAssertEqual(fixture.model.snapshot.defaultPresetID, builtIn.id)
        let deletedIDs = await fixture.prompts.deletedIDs()
        XCTAssertEqual(deletedIDs, [duplicate.id])
    }

    func testDefaultReplacementDeletionIsSerialized() async {
        let fixture = U8Fixture()
        await fixture.model.loadPromptPresets()
        let builtIn = try! XCTUnwrap(fixture.model.builtInPrompts.first)
        await fixture.model.duplicateBuiltInPrompt(builtIn.id)
        let custom = try! XCTUnwrap(fixture.model.promptDraft)
        await fixture.model.savePromptDraft()
        await fixture.model.setDefaultPreset(custom.id)
        await fixture.model.deletePrompt(custom.id)
        await fixture.prompts.suspendNextDelete()

        let first = Task {
            await fixture.model.deletePrompt(custom.id, replacement: builtIn.id)
        }
        await fixture.prompts.waitForSuspendedDelete()
        let second = Task {
            await fixture.model.deletePrompt(custom.id, replacement: builtIn.id)
        }
        await Task.yield()
        await fixture.prompts.resumeDelete()
        await first.value
        await second.value

        XCTAssertEqual(fixture.model.snapshot.defaultPresetID, builtIn.id)
        let deletedIDs = await fixture.prompts.deletedIDs()
        XCTAssertEqual(deletedIDs, [custom.id])
        XCTAssertNil(fixture.model.safeError)
    }
}

@MainActor
final class U8Fixture {
    let preferences: U8Preferences
    let prompts: U8PromptStore
    let history: U8History
    let diagnostics: U8Diagnostics
    let reset: U8Reset
    let refresh: U8Refresh
    let model: SettingsViewModel

    init(
        historyFailure: SanitizedFailure? = nil,
        history suppliedHistory: (any SettingsHistoryManaging)? = nil,
        diagnosticApproval: Bool = true,
        resetReport: ResetReport = .completed
    ) {
        let snapshot = U8Preferences.makeSnapshot()
        preferences = U8Preferences(snapshot)
        prompts = U8PromptStore()
        history = U8History(failure: historyFailure)
        diagnostics = U8Diagnostics(approval: diagnosticApproval)
        reset = U8Reset(report: resetReport)
        refresh = U8Refresh()
        let shortcut = ShortcutSettingsModel(
            registrar: U8ShortcutRegistrar(),
            currentDescriptor: snapshot.shortcut
        )
        model = SettingsViewModel(
            initialSnapshot: snapshot,
            preferences: preferences,
            shortcut: shortcut,
            launchAtLogin: U8Launch(),
            selection: U8Selection(),
            provider: U8Provider(),
            inspection: U8Inspection(),
            confirmation: U8Confirmation(),
            promptStore: prompts,
            history: suppliedHistory ?? history,
            diagnostics: diagnostics,
            reset: reset,
            runtimeRefresh: refresh
        )
    }
}

actor U8Preferences: PreferencesStore {
    private(set) var value: PreferencesSnapshot
    private(set) var writeCount = 0
    private var snapshotReadCount = 0
    private var rejectsSnapshots = false

    init(_ value: PreferencesSnapshot) { self.value = value }
    func snapshot() async throws -> PreferencesSnapshot {
        snapshotReadCount += 1
        if rejectsSnapshots { throw U8SyntheticPreferencesError() }
        return value
    }
    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        try transform(&value)
        writeCount += 1
    }
    func writes() -> Int { writeCount }
    func snapshotReads() -> Int { snapshotReadCount }
    func rejectFutureSnapshots() { rejectsSnapshots = true }
    func replace(_ snapshot: PreferencesSnapshot) { value = snapshot }

    nonisolated static func makeSnapshot() -> PreferencesSnapshot {
        try! JSONDecoder().decode(
            PreferencesSnapshot.self,
            from: JSONEncoder().encode(U8PreferencesFixture())
        )
    }
}

private struct U8SyntheticPreferencesError: Error {}

private struct U8PreferencesFixture: Codable {
    var uiLanguage = ApplicationLanguage.english
    var defaultTargetLanguage = LanguageChoice.identified("zh-Hans")
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

actor U8PromptStore: PromptPresetStore {
    private let validation = DefaultPromptPresetValidationService()
    private var custom: [CustomPreset] = []
    private var previews: [PresetID] = []
    private var deletes: [PresetID] = []
    private var suspendCustomLoad = false
    private var customLoadContinuation: CheckedContinuation<Void, Never>?
    private var suspendDelete = false
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    func builtIns() -> [PromptPresetDescriptor] { validation.builtIns() }
    func customPresets() async throws -> [CustomPreset] {
        if suspendCustomLoad {
            suspendCustomLoad = false
            await withCheckedContinuation { customLoadContinuation = $0 }
        }
        return custom
    }
    func duplicateBuiltIn(_ id: PresetID) throws -> CustomPreset {
        try validation.duplicateBuiltIn(id)
    }
    func validate(_ preset: CustomPreset) throws -> ValidatedPromptPreset {
        try validation.validate(preset)
    }
    func preview(_ id: PresetID) throws -> PromptPresetPreview {
        previews.append(id)
        if let preset = custom.first(where: { $0.id == id }) {
            return try validation.previewCustom(preset)
        }
        return try validation.previewBuiltIn(id)
    }
    func preview(
        _ id: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview {
        previews.append(id)
        if let preset = custom.first(where: { $0.id == id }) {
            return try validation.previewCustom(
                preset,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
        return try validation.previewBuiltIn(
            id,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }
    func validatedPreset(_ id: PresetID) throws -> ValidatedPromptPreset {
        if let preset = custom.first(where: { $0.id == id }) {
            return try validation.validate(preset)
        }
        return try validation.validatedBuiltIn(id)
    }
    func save(_ preset: CustomPreset) throws {
        _ = try validation.validate(preset)
        custom.removeAll { $0.id == preset.id }
        custom.append(preset)
    }
    func delete(_ id: PresetID) async throws {
        if validation.builtIns().contains(where: { $0.id == id }) {
            throw PromptPresetFailure.immutableBuiltIn
        }
        if suspendDelete {
            suspendDelete = false
            await withCheckedContinuation { deleteContinuation = $0 }
        }
        guard custom.contains(where: { $0.id == id }) else {
            throw PromptPresetFailure.presetNotFound
        }
        deletes.append(id)
        custom.removeAll { $0.id == id }
    }
    func previewIDs() -> [PresetID] { previews }
    func deletedIDs() -> [PresetID] { deletes }
    func suspendNextCustomLoad() { suspendCustomLoad = true }
    func waitForSuspendedCustomLoad() async {
        while customLoadContinuation == nil { await Task.yield() }
    }
    func resumeCustomLoad() {
        customLoadContinuation?.resume()
        customLoadContinuation = nil
    }
    func suspendNextDelete() { suspendDelete = true }
    func waitForSuspendedDelete() async {
        while deleteContinuation == nil { await Task.yield() }
    }
    func resumeDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}

actor U8History: SettingsHistoryManaging {
    enum Effect: Equatable { case maintenance, search, delete, clear }
    var records: [SettingsHistoryRecord] = []
    private(set) var effects: [Effect] = []
    let failure: SanitizedFailure?
    init(failure: SanitizedFailure?) { self.failure = failure }
    func performMaintenance() async throws {
        effects.append(.maintenance)
        if let failure { throw failure }
    }
    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord] {
        effects.append(.search)
        if let failure { throw failure }
        return records
    }
    func delete(_ id: TranslationRecordID) async throws {
        effects.append(.delete)
        if let failure { throw failure }
        records.removeAll { $0.id == id }
    }
    func clearAll() async throws {
        effects.append(.clear)
        if let failure, failure != .historyUnrecoverable { throw failure }
        records = []
    }
    func setRecords(_ value: [SettingsHistoryRecord]) { records = value }
    func recordedEffects() -> [Effect] { effects }
}

@MainActor
final class U8Diagnostics: SettingsDiagnosticsStarting, @unchecked Sendable {
    enum Effect: Equatable { case preview, savePanel, write }
    let approval: Bool
    private(set) var effects: [Effect] = []
    init(approval: Bool) { self.approval = approval }
    func start() async -> DiagnosticExportOutcome {
        effects.append(.preview)
        guard approval else { return .previewCancelled }
        effects.append(.savePanel)
        effects.append(.write)
        return .saved
    }
}

@MainActor
final class U8Reset: SettingsResetting, @unchecked Sendable {
    let report: ResetReport
    private(set) var count = 0
    init(report: ResetReport) { self.report = report }
    func resetAll() async -> ResetReport { count += 1; return report }
}

@MainActor
final class U8Refresh: SettingsRuntimeRefreshing, @unchecked Sendable {
    private(set) var count = 0
    private(set) var preservedReports: [ResetReport] = []
    var failAfterReset = false
    func resetAndReplace(using reset: any SettingsResetting) async throws -> ResetReport {
        let report = await reset.resetAll()
        count += 1
        preservedReports.append(report)
        if failAfterReset {
            throw SettingsRuntimeRefreshFailure.replacementFailed(report: report)
        }
        return report
    }
}

private actor U8ShortcutRegistrar: GlobalShortcutRegistering {
    func register(_ descriptor: ShortcutDescriptor) async throws {}
    func unregister() async {}
}

@MainActor private struct U8Launch: SettingsLaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) async throws {}
}
@MainActor private struct U8Selection: SettingsSelectionControlling {
    func setMouseEnabled(_ enabled: Bool) async throws {}
    func setKeyboardEnabled(_ enabled: Bool) async throws {}
    func accessibilityStatus() -> SettingsAccessibilityStatus { .unknown }
    func openAccessibilitySettings() {}
    func requestAccessibility() -> SettingsAccessibilityStatus { .unknown }
}
private struct U8Provider: SettingsProviderManaging {
    func descriptors() async throws -> [SettingsProviderDescriptor] { [] }
    func configuration(_ id: ProviderConfigurationID) async throws -> SettingsProviderDetails {
        throw SanitizedFailure.providerRecoveryRequired
    }
    func create(
        _ draft: SettingsProviderDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SettingsProviderDescriptor { throw SanitizedFailure.providerRecoveryRequired }
    func update(
        _ id: ProviderConfigurationID,
        draft: SettingsProviderDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SettingsProviderDescriptor { throw SanitizedFailure.providerRecoveryRequired }
    func automaticApplications(for id: ProviderConfigurationID) async throws -> Set<ApplicationIdentity> { [] }
    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {}
    func delete(_ id: ProviderConfigurationID) async throws {}
}
private struct U8Inspection: SettingsProviderInspecting {
    func discoverModels(for id: ProviderConfigurationID) async throws -> [String] { [] }
    func testConnection(for id: ProviderConfigurationID) async throws {}
}
private struct U8Confirmation: SettingsProviderConfirming {
    func prepare(
        for id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind
    ) async throws -> SettingsConfirmationPreview { throw SanitizedFailure.providerRecoveryRequired }
    func confirm(_ preview: SettingsConfirmationPreview) async throws {}
}
