import Foundation
import SharedSupport

public enum HistoryWriteOutcome: Equatable, Sendable {
    case stored
    case skipped(HistorySkipReason)
}

public enum HistorySkipReason: Equatable, Sendable {
    case disabled
    case excludedApplication
}

public enum HistoryQuery: Sendable {
    case all
    case contains(String)
}

public struct HistorySummary: Identifiable, Sendable {
    public let id: TranslationRecordID
    public let timestamp: Date
    public let presetID: PresetID
    public let sourcePreview: String
    public let resultPreview: String
}
