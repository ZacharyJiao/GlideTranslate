import SharedSupport

enum CaptureOutcomeCategory: String, Equatable, Sendable {
    case succeeded
    case rejected
    case timedOut
    case cancelled
}

enum ProviderHealthCategory: String, Equatable, Sendable {
    case available
    case unavailable
    case reconfirmationRequired
}

enum HistoryOutcomeCategory: String, Equatable, Sendable {
    case skippedDisabled
    case stored
    case removed
    case unrecoverable
}

enum AccessibilityPermissionCategory: String, Codable, Equatable, Sendable {
    case granted
    case denied
}

enum AppEvent: Equatable, Sendable {
    case captureOutcome(CaptureOutcomeCategory)
    case providerHealth(ProviderHealthCategory)
    case translationOutcome(
        SanitizedFailure?,
        durationMilliseconds: UInt64
    )
    case historyOutcome(HistoryOutcomeCategory)
    case permissionState(AccessibilityPermissionCategory)
}
