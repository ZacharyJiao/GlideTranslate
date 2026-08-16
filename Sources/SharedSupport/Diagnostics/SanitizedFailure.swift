public enum SanitizedFailure: String, CaseIterable, Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case applicationNotAllowed
    case noValidSelection
    case unsupportedApplication
    case unsafeFallbackState
    case ollamaUnavailable
    case modelUnavailable
    case invalidProviderConfiguration
    case invalidCredential
    case destinationReconfirmationRequired
    case connectionTimeout
    case firstTokenTimeout
    case streamIdleTimeout
    case providerProtocolFailure
    case cancelled
    case historyUnrecoverable
    case preferencesUnrecoverable
    case credentialStoreUnavailable
    case providerRecoveryRequired
}

public enum SelectionAuthorizationFailure: String, Error, Equatable, Sendable {
    case cancelled
    case automaticCapturePaused
    case mouseCaptureDisabled
    case keyboardCaptureDisabled
    case applicationNotAllowed
    case offDeviceApplicationNotAllowed
    case providerDestinationUnresolved
    case providerChanged
    case accessibilityPermissionMissing
    case unsupportedApplication
    case selectionReadTimedOut
    case noValidSelection
    case unsafeFallbackState
    case snapshotTooLarge
    case foregroundApplicationChanged
}
