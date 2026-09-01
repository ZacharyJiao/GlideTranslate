import SharedSupport
import SwiftUI

enum HistoryLayout {
    static let sidebarMinimumWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 320
    static let detailMinimumWidth: CGFloat = 360
    static let windowMinimumWidth: CGFloat = 680
    static let windowIdealWidth: CGFloat = 760
    static let windowMinimumHeight: CGFloat = 520
    static let windowIdealHeight: CGFloat = 560
    static let entryPreviewLimit = 80
}

struct HistoryDateGroup: Identifiable, Equatable, Sendable {
    let day: Date
    let records: [SettingsHistoryRecord]

    var id: Date { day }
}

extension SettingsHistoryRecord {
    var entryTitle: String {
        let source = sourcePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "—" }

        let firstSentence = source.firstIndex { character in
            ".!?。！？\n".contains(character)
        }.map { String(source[...$0]) }
        let candidate = firstSentence ?? source
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > HistoryLayout.entryPreviewLimit else {
            return trimmed
        }
        return String(trimmed.prefix(HistoryLayout.entryPreviewLimit)) + "…"
    }
}

struct HistoryView: View {
    @Bindable var viewModel: SettingsViewModel
    private let onClose: (@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedRecordID: TranslationRecordID?
    @State private var deleteCandidate: SettingsHistoryRecord?
    @State private var clearConfirmationPresented = false
    @State private var expandedDays: Set<Date> = []

    init(
        viewModel: SettingsViewModel,
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    static func groupedRecords(
        _ records: [SettingsHistoryRecord],
        calendar: Calendar = .current
    ) -> [HistoryDateGroup] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.timestamp) }
            .map { day, records in
                HistoryDateGroup(
                    day: day,
                    records: records.sorted { $0.timestamp > $1.timestamp }
                )
            }
            .sorted { $0.day > $1.day }
    }

    static func expandedDaysAfterLoad(
        current: Set<Date>,
        records: [SettingsHistoryRecord],
        calendar: Calendar = .current
    ) -> Set<Date> {
        guard current.isEmpty,
              let newestDay = groupedRecords(records, calendar: calendar).first?.day
        else { return current }
        return [newestDay]
    }

    static func selectionAfterLoad(
        current: TranslationRecordID?,
        records: [SettingsHistoryRecord]
    ) -> TranslationRecordID? {
        if let current, records.contains(where: { $0.id == current }) {
            return current
        }
        return records.max { $0.timestamp < $1.timestamp }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GlidePageHeader(
                    title: "privacyHistory.search",
                    explanation: "privacyHistory.search.explanation"
                )
                Spacer(minLength: 8)
                Button("privacyHistory.close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("history.close")
            }
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
                    List(selection: $selectedRecordID) {
                        ForEach(Self.groupedRecords(viewModel.historyRecords)) { group in
                            DisclosureGroup(
                                isExpanded: expansionBinding(for: group.day)
                            ) {
                                ForEach(group.records) { record in
                                    historyEntry(record)
                                }
                            } label: {
                                Text(group.day, style: .date)
                                    .font(.headline)
                            }
                        }
                    }
                    .frame(
                        minWidth: HistoryLayout.sidebarMinimumWidth,
                        idealWidth: HistoryLayout.sidebarIdealWidth,
                        maxWidth: HistoryLayout.sidebarMaximumWidth
                    )

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
                        .frame(minWidth: HistoryLayout.detailMinimumWidth)
                    } else {
                        ContentUnavailableView(
                            "privacyHistory.selection.empty",
                            systemImage: "clock"
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(
            minWidth: HistoryLayout.windowMinimumWidth,
            idealWidth: HistoryLayout.windowIdealWidth,
            minHeight: HistoryLayout.windowMinimumHeight,
            idealHeight: HistoryLayout.windowIdealHeight
        )
        .background(GlideVisualTokens.canvas)
        .task { await viewModel.performOwnedAndWait { await $0.openHistory() } }
        .onAppear {
            expandedDays = Self.expandedDaysAfterLoad(
                current: expandedDays,
                records: viewModel.historyRecords
            )
            selectedRecordID = Self.selectionAfterLoad(
                current: selectedRecordID,
                records: viewModel.historyRecords
            )
        }
        .onChange(of: viewModel.historyRecords) { _, records in
            expandedDays = Self.expandedDaysAfterLoad(
                current: expandedDays,
                records: records
            )
            selectedRecordID = Self.selectionAfterLoad(
                current: selectedRecordID,
                records: records
            )
        }
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

    private func close() {
        viewModel.clearHistoryViewCache()
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var selectedRecord: SettingsHistoryRecord? {
        guard let selectedRecordID else { return nil }
        return viewModel.historyRecords.first { $0.id == selectedRecordID }
    }

    private func historyEntry(_ record: SettingsHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: record.entryTitle)
                .lineLimit(2)
            Text(record.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .tag(Optional(record.id))
    }

    private func expansionBinding(for day: Date) -> Binding<Bool> {
        Binding(
            get: { expandedDays.contains(day) },
            set: { expanded in
                if expanded {
                    expandedDays.insert(day)
                } else {
                    expandedDays.remove(day)
                }
            }
        )
    }
}
