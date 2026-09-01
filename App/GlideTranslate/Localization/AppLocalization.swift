import Foundation
import ModelProviders
import Observation
import PrivacyStorage
import SharedSupport

@MainActor
@Observable
final class AppUILocaleState {
    static let shared = AppUILocaleState()
    private(set) var current: Locale

    init(current: Locale = Locale(identifier: "en")) {
        self.current = current
    }

    func set(_ language: ApplicationLanguage) {
        current = language.locale
    }
}

extension ApplicationLanguage {
    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

enum UITestingMode {
    static var isEnabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }

    static func includes(_ argument: String) -> Bool {
        includes(argument, arguments: ProcessInfo.processInfo.arguments)
    }

    static func isEnabled(arguments: [String]) -> Bool {
        arguments.contains("--ui-testing")
    }

    static func includes(_ argument: String, arguments: [String]) -> Bool {
        isEnabled(arguments: arguments) && arguments.contains(argument)
    }
}

struct SafeErrorPresentation: Equatable, Sendable {
    let messageKey: String
    let nextActionKey: String
}

enum SafeNextAction: Equatable, Sendable {
    case openAccessibilitySettingsOrUseManualInput
    case resumeAutomaticOrUseShortcut
    case enableApplicationOrUseShortcut
    case authorizeApplicationOrUseExplicitAction
    case openManualInput
    case useManualInput
    case showLocalRuntimeGuidance
    case chooseOrInstallModelManually
    case openModelSettings
    case replaceCredential
    case reconfirmDestination
    case retryOrAdjustTimeout
    case retryOrReviewProvider
    case none
    case explainHistoryDisabled
    case explainApplicationExcluded
    case deleteAndRestartHistory
}

struct SafeNextActionPresentation: Equatable, Sendable {
    let action: SafeNextAction
    let messageKey: String
    let nextActionKey: String
    let sanitizedFailure: SanitizedFailure?
}

extension SettingsSafeError {
    var localization: SafeErrorPresentation {
        let category = switch self {
        case .persistenceFailed: "persistenceFailed"
        case .shortcutUnavailable: "shortcutUnavailable"
        case .launchAtLoginUnavailable: "launchAtLoginUnavailable"
        case .selectionEffectUnavailable: "selectionEffectUnavailable"
        case .invalidValue: "invalidValue"
        case .providerUnavailable: "providerUnavailable"
        case .missingModel: "missingModel"
        case .destinationConfirmationRequired: "destinationConfirmationRequired"
        case .credentialRejected: "credentialRejected"
        case .providerFailure: "providerFailure"
        case .promptUnavailable: "promptUnavailable"
        case .promptReplacementRequired: "promptReplacementRequired"
        case .historyUnavailable: "historyUnavailable"
        case .diagnosticsUnavailable: "diagnosticsUnavailable"
        case .resetIncomplete: "resetIncomplete"
        case .runtimeRefreshUnavailable: "runtimeRefreshUnavailable"
        }
        return SafeErrorPresentation(
            messageKey: "error.settings.\(category).message",
            nextActionKey: "error.settings.\(category).nextAction"
        )
    }
}

extension OnboardingSafeError {
    var localization: SafeErrorPresentation {
        let category = switch self {
        case .explanationRequired: "explanationRequired"
        case .providerUnavailable: "providerUnavailable"
        case .shortcutUnavailable: "shortcutUnavailable"
        case .persistenceFailed: "persistenceFailed"
        case .invalidModel: "invalidModel"
        }
        return SafeErrorPresentation(
            messageKey: "error.onboarding.\(category).message",
            nextActionKey: "error.onboarding.\(category).nextAction"
        )
    }
}

extension SanitizedFailure {
    var localization: SafeErrorPresentation {
        let category = switch self {
        case .accessibilityPermissionMissing: "accessibilityPermissionMissing"
        case .applicationNotAllowed: "applicationNotAllowed"
        case .noValidSelection: "noValidSelection"
        case .unsupportedApplication: "unsupportedApplication"
        case .unsafeFallbackState: "unsafeFallbackState"
        case .ollamaUnavailable: "ollamaUnavailable"
        case .modelUnavailable: "modelUnavailable"
        case .invalidProviderConfiguration: "invalidProviderConfiguration"
        case .invalidCredential: "invalidCredential"
        case .destinationReconfirmationRequired: "destinationReconfirmationRequired"
        case .connectionTimeout: "connectionTimeout"
        case .firstTokenTimeout: "firstTokenTimeout"
        case .streamIdleTimeout: "streamIdleTimeout"
        case .providerProtocolFailure: "providerProtocolFailure"
        case .cancelled: "cancelled"
        case .historyUnrecoverable: "historyUnrecoverable"
        case .preferencesUnrecoverable: "preferencesUnrecoverable"
        case .credentialStoreUnavailable: "credentialStoreUnavailable"
        case .providerRecoveryRequired: "providerRecoveryRequired"
        }
        return SafeErrorPresentation(
            messageKey: "error.translation.\(category).message",
            nextActionKey: "error.translation.\(category).nextAction"
        )
    }

    var safeNextActionPresentation: SafeNextActionPresentation {
        let action: SafeNextAction = switch self {
        case .accessibilityPermissionMissing:
            .openAccessibilitySettingsOrUseManualInput
        case .applicationNotAllowed:
            .enableApplicationOrUseShortcut
        case .noValidSelection, .unsupportedApplication:
            .openManualInput
        case .unsafeFallbackState:
            .useManualInput
        case .ollamaUnavailable:
            .showLocalRuntimeGuidance
        case .modelUnavailable:
            .chooseOrInstallModelManually
        case .invalidProviderConfiguration, .preferencesUnrecoverable,
             .providerRecoveryRequired:
            .openModelSettings
        case .invalidCredential, .credentialStoreUnavailable:
            .replaceCredential
        case .destinationReconfirmationRequired:
            .reconfirmDestination
        case .connectionTimeout, .firstTokenTimeout, .streamIdleTimeout:
            .retryOrAdjustTimeout
        case .providerProtocolFailure:
            .retryOrReviewProvider
        case .cancelled:
            .none
        case .historyUnrecoverable:
            .deleteAndRestartHistory
        }
        return SafeNextActionPresentation(
            action: action,
            messageKey: localization.messageKey,
            nextActionKey: localization.nextActionKey,
            sanitizedFailure: self
        )
    }
}

extension SelectionAuthorizationFailure {
    var safeNextActionPresentation: SafeNextActionPresentation {
        let action: SafeNextAction
        let localization: SafeErrorPresentation
        let sanitizedFailure: SanitizedFailure
        switch self {
        case .cancelled:
            action = .none
            localization = SanitizedFailure.cancelled.localization
            sanitizedFailure = .cancelled
        case .automaticCapturePaused, .mouseCaptureDisabled, .keyboardCaptureDisabled:
            action = .resumeAutomaticOrUseShortcut
            localization = SafeErrorPresentation(
                messageKey: "error.translation.automaticCapturePaused.message",
                nextActionKey: "error.translation.automaticCapturePaused.nextAction"
            )
            sanitizedFailure = .applicationNotAllowed
        case .applicationNotAllowed:
            action = .enableApplicationOrUseShortcut
            localization = SanitizedFailure.applicationNotAllowed.localization
            sanitizedFailure = .applicationNotAllowed
        case .offDeviceApplicationNotAllowed:
            action = .authorizeApplicationOrUseExplicitAction
            localization = SafeErrorPresentation(
                messageKey: "error.translation.offDeviceApplicationNotAllowed.message",
                nextActionKey: "error.translation.offDeviceApplicationNotAllowed.nextAction"
            )
            sanitizedFailure = .applicationNotAllowed
        case .providerDestinationUnresolved, .providerChanged:
            action = .reconfirmDestination
            localization = SanitizedFailure.destinationReconfirmationRequired.localization
            sanitizedFailure = .destinationReconfirmationRequired
        case .accessibilityPermissionMissing:
            action = .openAccessibilitySettingsOrUseManualInput
            localization = SanitizedFailure.accessibilityPermissionMissing.localization
            sanitizedFailure = .accessibilityPermissionMissing
        case .unsupportedApplication:
            action = .openManualInput
            localization = SanitizedFailure.unsupportedApplication.localization
            sanitizedFailure = .unsupportedApplication
        case .selectionReadTimedOut:
            action = .retryOrAdjustTimeout
            localization = SanitizedFailure.connectionTimeout.localization
            sanitizedFailure = .connectionTimeout
        case .noValidSelection, .snapshotTooLarge:
            action = .openManualInput
            localization = SanitizedFailure.noValidSelection.localization
            sanitizedFailure = .noValidSelection
        case .unsafeFallbackState, .foregroundApplicationChanged:
            action = .useManualInput
            localization = SanitizedFailure.unsafeFallbackState.localization
            sanitizedFailure = .unsafeFallbackState
        }
        return SafeNextActionPresentation(
            action: action,
            messageKey: localization.messageKey,
            nextActionKey: localization.nextActionKey,
            sanitizedFailure: sanitizedFailure
        )
    }
}

extension HistoryWriteOutcome {
    var safeNextActionPresentation: SafeNextActionPresentation? {
        switch self {
        case .stored:
            nil
        case let .skipped(reason):
            reason.safeNextActionPresentation
        }
    }
}

extension HistorySkipReason {
    var safeNextActionPresentation: SafeNextActionPresentation {
        switch self {
        case .disabled:
            SafeNextActionPresentation(
                action: .explainHistoryDisabled,
                messageKey: "error.translation.historyDisabled.message",
                nextActionKey: "error.translation.historyDisabled.nextAction",
                sanitizedFailure: nil
            )
        case .excludedApplication:
            SafeNextActionPresentation(
                action: .explainApplicationExcluded,
                messageKey: "error.translation.applicationExcluded.message",
                nextActionKey: "error.translation.applicationExcluded.nextAction",
                sanitizedFailure: nil
            )
        }
    }
}

extension ProviderProtocolKind {
    var localizationKey: String {
        switch self {
        case .ollamaNative: "models.ollama"
        case .openAICompatible: "models.openAICompatible"
        }
    }
}

extension DestinationPrivacyClass {
    var localizationKey: String {
        switch self {
        case .localOnDevice: "locality.local"
        case .localNetwork: "locality.network"
        case .cloud: "locality.cloud"
        case .unresolvedOrChanged: "locality.unresolved"
        }
    }
}

extension ProviderReadiness {
    var localizationKey: String {
        "provider.readiness.\(rawValue)"
    }
}

extension PresetID {
    static let builtInDisplayIDs = [
        PresetID(rawValue: "accurate-translation"),
        PresetID(rawValue: "natural-translation"),
        PresetID(rawValue: "explain-word"),
        PresetID(rawValue: "explain-sentence"),
        PresetID(rawValue: "polish-expression"),
    ]

    var safeDisplayLocalizationKey: String {
        switch rawValue {
        case "accurate-translation": "preset.accurate.name"
        case "natural-translation": "preset.natural.name"
        case "explain-word": "preset.explainWord.name"
        case "explain-sentence": "preset.explainSentence.name"
        case "polish-expression": "preset.polish.name"
        default: "preset.custom.name"
        }
    }
}
