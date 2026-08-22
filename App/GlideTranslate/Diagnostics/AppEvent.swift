import SelectionCapture
import SharedSupport

enum CaptureOutcomeCategory: String, Equatable, Sendable {
    case succeeded
    case rejected
    case timedOut
    case cancelled
}

enum CaptureTriggerCategory: String, Equatable, Sendable {
    case mouse
    case keyboardSelection
}

enum CaptureFailureCategory: String, CaseIterable, Equatable, Sendable {
    case noValidSelection
    case unsupportedApplication
    case foregroundApplicationChanged
    case permission
    case policy
    case cancelled
    case timeout
    case providerDrift
    case other
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
    case captureTriggerReceived(CaptureTriggerCategory)
    case shortcutReceived
    case captureOutcome(CaptureOutcomeCategory)
    case captureFailure(CaptureFailureCategory)
    case selectionAXDiagnostic(SelectionAXDiagnostic)
    case providerHealth(ProviderHealthCategory)
    case translationOutcome(
        SanitizedFailure?,
        durationMilliseconds: UInt64
    )
    case historyOutcome(HistoryOutcomeCategory)
    case permissionState(AccessibilityPermissionCategory)
}

extension SelectionAuthorizationFailure {
    var captureFailureCategory: CaptureFailureCategory {
        switch self {
        case .noValidSelection:
            .noValidSelection
        case .unsupportedApplication:
            .unsupportedApplication
        case .foregroundApplicationChanged:
            .foregroundApplicationChanged
        case .accessibilityPermissionMissing:
            .permission
        case .automaticCapturePaused,
             .mouseCaptureDisabled,
             .keyboardCaptureDisabled,
             .applicationNotAllowed,
             .offDeviceApplicationNotAllowed:
            .policy
        case .cancelled:
            .cancelled
        case .selectionReadTimedOut:
            .timeout
        case .providerDestinationUnresolved,
             .providerChanged:
            .providerDrift
        case .unsafeFallbackState,
             .snapshotTooLarge:
            .other
        }
    }
}
