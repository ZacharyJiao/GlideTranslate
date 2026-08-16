import Foundation

enum ResetStage: String, CaseIterable, Codable, Sendable {
    case pauseCapture
    case cancelRequests
    case unregisterShortcut
    case closeStores
    case unregisterLaunchAtLogin
    case deleteHistoryStoreAndKey
    case deletePrivatePresetStoreAndKey
    case deleteProviderVault
    case resetPreferences
    case clearCaches
}

enum ResetReport: Equatable, Sendable {
    case completed
    case partialFailure(Set<ResetStage>)

    var failedStages: Set<ResetStage> {
        switch self {
        case .completed:
            []
        case .partialFailure(let stages):
            stages
        }
    }
}
