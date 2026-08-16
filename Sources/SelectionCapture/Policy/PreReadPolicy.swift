import SharedSupport

package enum PreReadDecision: Equatable, Sendable {
    case accessibility
    case accessibilityWithOptionalClipboard
    case manual
    case rejected(PreReadFailure)
}

package enum PreReadFailure: Equatable, Sendable {
    case automaticCapturePaused
    case mouseCaptureDisabled
    case keyboardCaptureDisabled
    case applicationNotAllowed
    case offDeviceApplicationNotAllowed
    case providerDestinationUnresolved
}

package enum PreReadPolicy {
    package static func evaluate(
        trigger: CaptureTrigger,
        application: ApplicationIdentity,
        policy: CapturePolicySnapshot,
        privacyClass: DestinationPrivacyClass
    ) -> PreReadDecision {
        switch trigger {
        case .mouse:
            guard policy.mouseSelectionEnabled else {
                return .rejected(.mouseCaptureDisabled)
            }
            guard policy.automaticCaptureEnabled else {
                return .rejected(.automaticCapturePaused)
            }
            guard policy.generalAllowlist.contains(application) else {
                return .rejected(.applicationNotAllowed)
            }
            if let rejection = automaticDestinationDecision(
                application: application,
                policy: policy,
                privacyClass: privacyClass
            ) {
                return rejection
            }
            return .accessibility

        case .keyboardSelection:
            guard policy.keyboardSelectionEnabled else {
                return .rejected(.keyboardCaptureDisabled)
            }
            guard policy.automaticCaptureEnabled else {
                return .rejected(.automaticCapturePaused)
            }
            guard policy.generalAllowlist.contains(application) else {
                return .rejected(.applicationNotAllowed)
            }
            if let rejection = automaticDestinationDecision(
                application: application,
                policy: policy,
                privacyClass: privacyClass
            ) {
                return rejection
            }
            return .accessibility

        case .shortcut:
            guard privacyClass != .unresolvedOrChanged else {
                return .rejected(.providerDestinationUnresolved)
            }
            return policy.clipboardFallbackEnabled
                ? .accessibilityWithOptionalClipboard
                : .accessibility

        case .manualInput:
            guard privacyClass != .unresolvedOrChanged else {
                return .rejected(.providerDestinationUnresolved)
            }
            return .manual
        }
    }

    private static func automaticDestinationDecision(
        application: ApplicationIdentity,
        policy: CapturePolicySnapshot,
        privacyClass: DestinationPrivacyClass
    ) -> PreReadDecision? {
        switch privacyClass {
        case .localOnDevice:
            return nil
        case .localNetwork, .cloud:
            return policy.offDeviceAllowlist.contains(application)
                ? nil
                : .rejected(.offDeviceApplicationNotAllowed)
        case .unresolvedOrChanged:
            return .rejected(.providerDestinationUnresolved)
        }
    }
}
