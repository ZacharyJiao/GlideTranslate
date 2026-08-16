import SharedSupport
import SwiftUI

struct HistoryView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var query = ""
    @State private var deleteCandidate: SettingsHistoryRecord?
    @State private var clearConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                List(viewModel.historyRecords) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.timestamp, style: .date)
                        if let presetDisplayName = record.presetDisplayName {
                            Text(verbatim: presetDisplayName)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(LocalizedStringKey(record.presetID.safeDisplayLocalizationKey))
                                .foregroundStyle(.secondary)
                        }
                        Text(record.sourcePreview)
                        Text(record.resultPreview).foregroundStyle(.secondary)
                        Button("privacyHistory.delete", role: .destructive) {
                            deleteCandidate = record
                        }
                        .accessibilityHint("privacyHistory.delete.hint")
                        .disabled(viewModel.historyMutationInFlight)
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
}
