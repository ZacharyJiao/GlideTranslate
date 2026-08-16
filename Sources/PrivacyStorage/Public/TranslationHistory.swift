import SharedSupport

public protocol TranslationHistory: Sendable {
    func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome
    func search(_ query: HistoryQuery) async throws -> [HistorySummary]
    func performMaintenance() async throws
    func delete(_ id: TranslationRecordID) async throws
    func clearAll() async throws
}
