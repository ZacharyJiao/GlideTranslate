import PrivacyStorage
import SharedSupport
import SwiftUI
import TranslationCore

enum HistoryUIRow: Equatable, Sendable {
    case initial(enabled: Bool, recordsShown: Int)
    case enable(explainsFutureWritesAndRetention: Bool)
    case disable(existingRecordsRemain: Bool)
    case retentionBounds(minimum: Int, maximum: Int)
    case maximumCountBounds(minimum: Int, maximum: Int)
    case search(decryptedCachePersisted: Bool)
    case excludeApplication(storedInPreferencesOnly: Bool)
    case deleteOne(confirm: Bool)
    case clearAll(confirm: Bool)
    case unrecoverable(showsDeleteAndRestart: Bool, appearsEmpty: Bool)
    case diagnostics(previewBeforeSave: Bool)
    case reset(confirm: Bool)
}

enum PrivacyHistorySettingsContract {
    static let rows: [HistoryUIRow] = [
        .initial(enabled: false, recordsShown: 0),
        .enable(explainsFutureWritesAndRetention: true),
        .disable(existingRecordsRemain: true),
        .retentionBounds(minimum: 1, maximum: 365),
        .maximumCountBounds(minimum: 1, maximum: 10_000),
        .search(decryptedCachePersisted: false),
        .excludeApplication(storedInPreferencesOnly: true),
        .deleteOne(confirm: true),
        .clearAll(confirm: true),
        .unrecoverable(showsDeleteAndRestart: true, appearsEmpty: false),
        .diagnostics(previewBeforeSave: true),
        .reset(confirm: true),
    ]
}

struct SettingsHistoryRecord: Identifiable, Equatable, Sendable {
    let id: TranslationRecordID
    let timestamp: Date
    let presetID: PresetID
    let presetDisplayName: String?
    let sourcePreview: String
    let resultPreview: String

    init(
        id: TranslationRecordID,
        timestamp: Date,
        presetID: PresetID,
        presetDisplayName: String? = nil,
        sourcePreview: String,
        resultPreview: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.presetID = presetID
        self.presetDisplayName = presetDisplayName
        self.sourcePreview = sourcePreview
        self.resultPreview = resultPreview
    }
}

enum SettingsHistoryState: Equatable, Sendable {
    case idle
    case loaded
    case unrecoverable
    case deleteAndRestartCompleted
}

protocol SettingsHistoryManaging: Sendable {
    func performMaintenance() async throws
    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord]
    func delete(_ id: TranslationRecordID) async throws
    func clearAll() async throws
}

enum SettingsHistoryFailure: Error, Equatable, Sendable {
    case unrecoverable
}

struct ProductionSettingsHistoryManager: SettingsHistoryManaging {
    let history: any TranslationHistory
    let promptPresets: (any PromptPresetStore)?

    init(
        history: any TranslationHistory,
        promptPresets: (any PromptPresetStore)? = nil
    ) {
        self.history = history
        self.promptPresets = promptPresets
    }

    func performMaintenance() async throws {
        do {
            try await history.performMaintenance()
        } catch {
            throw SettingsHistoryFailure.unrecoverable
        }
    }

    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord] {
        do {
            let summaries = try await history.search(query)
            let customNames: [PresetID: String]
            if let promptPresets,
               let presets = try? await promptPresets.customPresets() {
                customNames = Dictionary(
                    presets.map { ($0.id, $0.name) },
                    uniquingKeysWith: { first, _ in first }
                )
            } else {
                customNames = [:]
            }
            return summaries.map {
                SettingsHistoryRecord(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    presetID: $0.presetID,
                    presetDisplayName: customNames[$0.presetID],
                    sourcePreview: $0.sourcePreview,
                    resultPreview: $0.resultPreview
                )
            }
        } catch {
            throw SettingsHistoryFailure.unrecoverable
        }
    }

    func delete(_ id: TranslationRecordID) async throws {
        do {
            try await history.delete(id)
        } catch {
            throw SettingsHistoryFailure.unrecoverable
        }
    }

    func clearAll() async throws {
        do {
            try await history.clearAll()
        } catch {
            throw SettingsHistoryFailure.unrecoverable
        }
    }
}

@MainActor
protocol SettingsDiagnosticsStarting: Sendable {
    func start() async -> DiagnosticExportOutcome
}

extension DiagnosticExportCoordinator: SettingsDiagnosticsStarting {}

@MainActor
protocol SettingsResetting: Sendable {
    func resetAll() async -> ResetReport
}

extension PrivacyResetService: SettingsResetting {}

@MainActor
protocol SettingsRuntimeRefreshing: Sendable {
    /// Acquires the application runtime-transition lease before invoking
    /// `reset`, holds it through replacement publication, and returns the
    /// report handed to the replacement settings presentation.
    func resetAndReplace(using reset: any SettingsResetting) async throws -> ResetReport
}

enum SettingsRuntimeRefreshFailure: Error, Equatable, Sendable {
    case replacementFailed(report: ResetReport)

    var report: ResetReport {
        switch self {
        case let .replacementFailed(report): report
        }
    }
}

struct PrivacyHistorySettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var historyPresented = false
    @State private var resetConfirmationPresented = false

    var body: some View {
        Form {
            Section("privacyHistory.enabled") {
                Toggle("privacyHistory.enabled", isOn: historyEnabled)
                Text(viewModel.snapshot.historyEnabled
                     ? LocalizedStringKey("privacyHistory.enabled.futureWritesAndRetention")
                     : LocalizedStringKey("privacyHistory.disabled.existingRecordsRemain"))
            }
            .accessibilityIdentifier("privacyHistory.enabled")

            Stepper(
                value: retentionDays,
                in: 1...365
            ) {
                LabeledContent(
                    "privacyHistory.retention",
                    value: "\(viewModel.snapshot.historyRetentionDays)"
                )
            }
            .accessibilityValue("\(viewModel.snapshot.historyRetentionDays)")
            .accessibilityIdentifier("privacyHistory.retention")

            Stepper(
                value: maximumCount,
                in: 1...10_000
            ) {
                LabeledContent(
                    "privacyHistory.maximumCount",
                    value: "\(viewModel.snapshot.historyMaximumCount)"
                )
            }
            .accessibilityValue("\(viewModel.snapshot.historyMaximumCount)")
            .accessibilityLabel("privacyHistory.maximumCount.accessibility")
            .accessibilityIdentifier("privacyHistory.maximumCount")

            Section("privacyHistory.exclusions") {
                Text("privacyHistory.exclusions.preferencesOnly")
                ForEach(
                    viewModel.snapshot.generalAutomaticApplications.sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    },
                    id: \.bundleIdentifier
                ) { application in
                    Toggle(
                        application.displayName,
                        isOn: exclusion(application)
                    )
                }
            }
            .accessibilityIdentifier("privacyHistory.exclusions")

            Button("privacyHistory.search") { historyPresented = true }
                .accessibilityIdentifier("privacyHistory.search")

            Section("privacyHistory.diagnostics") {
                Text("privacyHistory.diagnostics.previewFirst")
                Button("privacyHistory.diagnostics.start") {
                    viewModel.performOwned { await $0.startDiagnostics() }
                }
                .accessibilityHint("privacyHistory.diagnostics.start.hint")
                .disabled(viewModel.diagnosticsInFlight)
            }
            .accessibilityIdentifier("privacyHistory.diagnostics")

            Button("privacyHistory.reset", role: .destructive) {
                resetConfirmationPresented = true
            }
            .accessibilityHint("privacyHistory.reset.hint")
            .disabled(viewModel.resetInFlight)
            .accessibilityIdentifier("privacyHistory.reset")

            Color.clear.frame(height: 0).accessibilityIdentifier("privacyHistory.delete")
            Color.clear.frame(height: 0).accessibilityIdentifier("privacyHistory.clear")

            if let report = viewModel.resetReport {
                Section("privacyHistory.reset.report") {
                    if report.failedStages.isEmpty {
                        Text("privacyHistory.reset.completed")
                    } else {
                        ForEach(report.failedStages.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) {
                            Text(LocalizedStringKey("privacyHistory.reset.stage.\($0.rawValue)"))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $historyPresented) {
            HistoryView(viewModel: viewModel)
                .frame(minWidth: 680, minHeight: 520)
        }
        .confirmationDialog(
            "privacyHistory.reset.confirm.title",
            isPresented: $resetConfirmationPresented
        ) {
            Button("privacyHistory.reset.confirm", role: .destructive) {
                Task { await viewModel.confirmReset() }
            }
            .accessibilityHint("privacyHistory.reset.confirm.hint")
        } message: {
            Text("privacyHistory.reset.confirm.categoriesAndKeychainCaveat")
        }
    }

    private var historyEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.historyEnabled },
            set: { value in
                viewModel.performOwned { await $0.setHistoryEnabled(value) }
            }
        )
    }

    private var retentionDays: Binding<Int> {
        Binding(
            get: { viewModel.snapshot.historyRetentionDays },
            set: { value in
                viewModel.performOwned { await $0.setHistoryRetentionDays(value) }
            }
        )
    }

    private var maximumCount: Binding<Int> {
        Binding(
            get: { viewModel.snapshot.historyMaximumCount },
            set: { value in
                viewModel.performOwned { await $0.setHistoryMaximumCount(value) }
            }
        )
    }

    private func exclusion(_ application: ApplicationIdentity) -> Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.historyExcludedApplications.contains(application) },
            set: { excluded in
                var applications = viewModel.snapshot.historyExcludedApplications
                if excluded { applications.insert(application) }
                else { applications.remove(application) }
                viewModel.performOwned {
                    await $0.setHistoryExcludedApplications(applications)
                }
            }
        )
    }
}

struct UnavailableSettingsHistory: SettingsHistoryManaging {
    func performMaintenance() async throws { throw SanitizedFailure.historyUnrecoverable }
    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord] {
        throw SanitizedFailure.historyUnrecoverable
    }
    func delete(_ id: TranslationRecordID) async throws {
        throw SanitizedFailure.historyUnrecoverable
    }
    func clearAll() async throws { throw SanitizedFailure.historyUnrecoverable }
}

@MainActor
struct UnavailableSettingsDiagnostics: SettingsDiagnosticsStarting {
    func start() async -> DiagnosticExportOutcome { .failed }
}

@MainActor
struct UnavailableSettingsReset: SettingsResetting {
    func resetAll() async -> ResetReport { .partialFailure(Set(ResetStage.allCases)) }
}

@MainActor
struct NoopSettingsRuntimeRefresh: SettingsRuntimeRefreshing {
    func resetAndReplace(using reset: any SettingsResetting) async throws -> ResetReport {
        await reset.resetAll()
    }
}
