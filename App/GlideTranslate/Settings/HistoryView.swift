import SharedSupport
import SwiftUI

struct HistoryView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var query = ""
    @State private var selectedRecordID: TranslationRecordID?
    @State private var deleteCandidate: SettingsHistoryRecord?
    @State private var clearConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlidePageHeader(
                title: "privacyHistory.search",
                explanation: "privacyHistory.search.explanation"
            )
            TextField("privacyHistory.search.query", text: $query)
                .onSubmit {
                    viewModel.performOwned { await $0.searchHistory(query) }
                }
                .disabled(
                    viewModel.historyState != .loaded || viewModel.historyMutationInFlight
                )

            switch viewModel.historyState {
            case .unrecoverable:
                ContentUnavailableView(
                    "privacyHistory.unrecoverable.title",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("privacyHistory.unrecoverable.description")
                )
                Button("privacyHistory.unrecoverable.deleteAndRestart", role: .destructive) {
                    viewModel.performOwned {
                        await $0.deleteUnrecoverableHistoryAndRestart()
                    }
                }
                .accessibilityHint("privacyHistory.unrecoverable.deleteAndRestart.hint")
                .disabled(viewModel.historyMutationInFlight)
            case .deleteAndRestartCompleted:
                Text("privacyHistory.unrecoverable.restartRequired")
            case .idle, .loaded:
                HSplitView {
                    List(viewModel.historyRecords, selection: $selectedRecordID) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.timestamp, style: .date)
                            if let presetDisplayName = record.presetDisplayName {
                                Text(verbatim: presetDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(LocalizedStringKey(record.presetID.safeDisplayLocalizationKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(Optional(record.id))
                    }
                    .frame(minWidth: 220, idealWidth: 250)

                    if let selectedRecord {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(selectedRecord.timestamp, format: .dateTime)
                                    .font(.headline)
                                Text(selectedRecord.sourcePreview)
                                Divider()
                                Text(selectedRecord.resultPreview)
                                    .foregroundStyle(.secondary)
                                Button("privacyHistory.delete", role: .destructive) {
                                    deleteCandidate = selectedRecord
                                }
                                .accessibilityHint("privacyHistory.delete.hint")
                                .disabled(viewModel.historyMutationInFlight)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                    } else {
                        ContentUnavailableView(
                            "privacyHistory.selection.empty",
                            systemImage: "clock"
                        )
                    }
                }
            }

            HStack {
                Button("privacyHistory.search.run") {
                    viewModel.performOwned { await $0.searchHistory(query) }
                }
                .disabled(
                    viewModel.historyState != .loaded || viewModel.historyMutationInFlight
                )
                Spacer()
                Button("privacyHistory.clear", role: .destructive) {
                    clearConfirmationPresented = true
                }
                .accessibilityHint("privacyHistory.clear.hint")
                .disabled(viewModel.historyMutationInFlight)
                .disabled(viewModel.historyState != .loaded)
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 520)
        .background(GlideVisualTokens.canvas)
        .task { await viewModel.performOwnedAndWait { await $0.openHistory() } }
        .onDisappear { viewModel.clearHistoryViewCache() }
        .confirmationDialog(
            "privacyHistory.delete.confirm.title",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("privacyHistory.delete.confirm", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                viewModel.performOwned {
                    await $0.deleteHistoryRecord(candidate.id)
                }
                deleteCandidate = nil
            }
            .accessibilityHint("privacyHistory.delete.confirm.hint")
            .disabled(viewModel.historyMutationInFlight)
        } message: {
            if let candidate = deleteCandidate {
                VStack(alignment: .leading) {
                    Text(candidate.timestamp, format: .dateTime)
                    Text(promptCategory(candidate.presetID))
                }
            }
        }
        .confirmationDialog(
            "privacyHistory.clear.confirm.title",
            isPresented: $clearConfirmationPresented
        ) {
            Button("privacyHistory.clear.confirm", role: .destructive) {
                viewModel.performOwned { await $0.clearHistory() }
            }
            .accessibilityHint("privacyHistory.clear.confirm.hint")
            .disabled(viewModel.historyMutationInFlight)
        } message: {
            Text("privacyHistory.clear.confirm.encryptedHistoryAndKey")
        }
    }

    private func promptCategory(_ id: PresetID) -> LocalizedStringKey {
        id.rawValue.hasPrefix("custom-")
            ? "privacyHistory.delete.presetCategory.custom"
            : "privacyHistory.delete.presetCategory.builtIn"
    }

    private var selectedRecord: SettingsHistoryRecord? {
        guard let selectedRecordID else { return nil }
        return viewModel.historyRecords.first { $0.id == selectedRecordID }
    }
}
