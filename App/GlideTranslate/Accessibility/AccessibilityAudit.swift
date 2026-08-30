import SwiftUI

enum AccessibilityKeyboardCommand: Equatable, Sendable {
    case escape
    case commandC
    case commandReturn
    case commandComma
}

enum AccessibilityAuditRow: Equatable, Sendable {
    case iconOnlyButtonsHaveLabels
    case stateControlsExposeValues
    case destructiveAndPermissionActionsHaveHints
    case streamingResult(stableHeading: Bool, readsEveryDelta: Bool)
    case focusOrderFollowsVisualHierarchy
    case keyboard(
        close: AccessibilityKeyboardCommand,
        copy: AccessibilityKeyboardCommand,
        translate: AccessibilityKeyboardCommand,
        settings: AccessibilityKeyboardCommand
    )
    case motion(
        reducedUsesAnimation: Bool,
        standardMaximumDurationMilliseconds: Int
    )
}

enum AccessibilityAudit {
    static let rows: [AccessibilityAuditRow] = [
        .iconOnlyButtonsHaveLabels,
        .stateControlsExposeValues,
        .destructiveAndPermissionActionsHaveHints,
        .streamingResult(stableHeading: true, readsEveryDelta: false),
        .focusOrderFollowsVisualHierarchy,
        .keyboard(close: .escape, copy: .commandC,
                  translate: .commandReturn, settings: .commandComma),
        .motion(reducedUsesAnimation: false,
                standardMaximumDurationMilliseconds: 160),
    ]
}

enum PanelMotionPolicy {
    static let standardDuration = GlideMotionTokens.surfaceDuration
    static let resizeDuration = GlideMotionTokens.resizeDuration
    static let contentCrossfadeDuration = GlideMotionTokens.contentCrossfadeDuration

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: standardDuration)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .identity
            : .opacity
    }

    static func shouldApplyImmediately(reduceMotion: Bool) -> Bool {
        reduceMotion
    }

    static func entryOffset(
        side: PanelAnchorSide,
        pointerCorner: PanelPointerCorner?
    ) -> CGSize {
        switch side {
        case .below:
            CGSize(width: 0, height: -8)
        case .above:
            CGSize(width: 0, height: 8)
        case .pointer:
            switch pointerCorner ?? .topLeft {
            case .topLeft: CGSize(width: 8, height: -8)
            case .topRight: CGSize(width: -8, height: -8)
            case .bottomLeft: CGSize(width: 8, height: 8)
            case .bottomRight: CGSize(width: -8, height: 8)
            }
        }
    }
}

enum LocalizationInventory {
    // Dynamic LocalizedStringKey families are enumerated here so the checker
    // can review them even though source extraction cannot resolve interpolation.
    static let dynamicKeys: [String] = [
        "about.releases", "about.source",
        "app.startup.failure.captureUnavailable",
        "app.startup.failure.corruptPreferences",
        "app.startup.failure.historyMaintenanceFailure",
        "app.startup.failure.partialShutdown",
        "app.startup.failure.providerVaultRecoveryRequired",
        "app.startup.failure.shortcutConflict",
        "error.onboarding.explanationRequired.message",
        "error.onboarding.explanationRequired.nextAction",
        "error.onboarding.invalidModel.message",
        "error.onboarding.invalidModel.nextAction",
        "error.onboarding.persistenceFailed.message",
        "error.onboarding.persistenceFailed.nextAction",
        "error.onboarding.providerUnavailable.message",
        "error.onboarding.providerUnavailable.nextAction",
        "error.onboarding.shortcutUnavailable.message",
        "error.onboarding.shortcutUnavailable.nextAction",
        "error.settings.confirmationChanged.message",
        "error.settings.confirmationChanged.nextAction",
        "error.settings.diagnosticsUnavailable.message",
        "error.settings.diagnosticsUnavailable.nextAction",
        "error.settings.historyUnavailable.message",
        "error.settings.historyUnavailable.nextAction",
        "error.settings.invalidValue.message",
        "error.settings.invalidValue.nextAction",
        "error.settings.launchAtLoginUnavailable.message",
        "error.settings.launchAtLoginUnavailable.nextAction",
        "error.settings.persistenceFailed.message",
        "error.settings.persistenceFailed.nextAction",
        "error.settings.promptReplacementRequired.message",
        "error.settings.promptReplacementRequired.nextAction",
        "error.settings.promptUnavailable.message",
        "error.settings.promptUnavailable.nextAction",
        "error.settings.providerUnavailable.message",
        "error.settings.providerUnavailable.nextAction",
        "error.settings.resetIncomplete.message",
        "error.settings.resetIncomplete.nextAction",
        "error.settings.runtimeRefreshUnavailable.message",
        "error.settings.runtimeRefreshUnavailable.nextAction",
        "error.settings.selectionEffectUnavailable.message",
        "error.settings.selectionEffectUnavailable.nextAction",
        "error.settings.shortcutUnavailable.message",
        "error.settings.shortcutUnavailable.nextAction",
        "error.translation.accessibilityPermissionMissing.message",
        "error.translation.accessibilityPermissionMissing.nextAction",
        "error.translation.applicationNotAllowed.message",
        "error.translation.applicationNotAllowed.nextAction",
        "error.translation.applicationExcluded.message",
        "error.translation.applicationExcluded.nextAction",
        "error.translation.automaticCapturePaused.message",
        "error.translation.automaticCapturePaused.nextAction",
        "error.translation.cancelled.message",
        "error.translation.cancelled.nextAction",
        "error.translation.connectionTimeout.message",
        "error.translation.connectionTimeout.nextAction",
        "error.translation.credentialStoreUnavailable.message",
        "error.translation.credentialStoreUnavailable.nextAction",
        "error.translation.destinationReconfirmationRequired.message",
        "error.translation.destinationReconfirmationRequired.nextAction",
        "error.translation.firstTokenTimeout.message",
        "error.translation.firstTokenTimeout.nextAction",
        "error.translation.historyUnrecoverable.message",
        "error.translation.historyUnrecoverable.nextAction",
        "error.translation.historyDisabled.message",
        "error.translation.historyDisabled.nextAction",
        "error.translation.invalidCredential.message",
        "error.translation.invalidCredential.nextAction",
        "error.translation.invalidProviderConfiguration.message",
        "error.translation.invalidProviderConfiguration.nextAction",
        "error.translation.modelUnavailable.message",
        "error.translation.modelUnavailable.nextAction",
        "error.translation.noValidSelection.message",
        "error.translation.noValidSelection.nextAction",
        "error.translation.offDeviceApplicationNotAllowed.message",
        "error.translation.offDeviceApplicationNotAllowed.nextAction",
        "error.translation.ollamaUnavailable.message",
        "error.translation.ollamaUnavailable.nextAction",
        "error.translation.preferencesUnrecoverable.message",
        "error.translation.preferencesUnrecoverable.nextAction",
        "error.translation.providerProtocolFailure.message",
        "error.translation.providerProtocolFailure.nextAction",
        "error.translation.providerRecoveryRequired.message",
        "error.translation.providerRecoveryRequired.nextAction",
        "error.translation.streamIdleTimeout.message",
        "error.translation.streamIdleTimeout.nextAction",
        "error.translation.unsafeFallbackState.message",
        "error.translation.unsafeFallbackState.nextAction",
        "error.translation.unsupportedApplication.message",
        "error.translation.unsupportedApplication.nextAction",
        "general.shortcut.persistenceFailed",
        "general.shortcut.ready",
        "locality.cloud", "locality.local", "locality.network", "locality.unresolved",
        "manual.provider.default", "manual.validation.empty", "manual.validation.missingSelection",
        "manual.validation.ready", "manual.validation.tooLong",
        "menu.pause", "menu.resolveInSettings", "menu.resume", "menu.state.appDisabled",
        "menu.state.capture", "menu.state.history", "menu.state.paused",
        "menu.state.permission", "menu.state.provider", "menu.state.resetting",
        "menu.state.running", "menu.state.shortcut",
        "models.credential.preserve", "models.credential.remove", "models.credential.replace",
        "preset.accurate.explanation", "preset.accurate.name",
        "preset.explainSentence.explanation", "preset.explainSentence.name",
        "preset.explainWord.explanation", "preset.explainWord.name",
        "preset.natural.explanation", "preset.natural.name",
        "preset.polish.explanation", "preset.polish.name",
        "privacyHistory.delete.presetCategory.builtIn",
        "privacyHistory.delete.presetCategory.custom",
        "privacyHistory.reset.stage.cancelRequests",
        "privacyHistory.reset.stage.clearCaches",
        "privacyHistory.reset.stage.closeStores",
        "privacyHistory.reset.stage.deleteHistoryStoreAndKey",
        "privacyHistory.reset.stage.deletePrivatePresetStoreAndKey",
        "privacyHistory.reset.stage.deleteProviderVault",
        "privacyHistory.reset.stage.pauseCapture",
        "privacyHistory.reset.stage.resetPreferences",
        "privacyHistory.reset.stage.unregisterLaunchAtLogin",
        "privacyHistory.reset.stage.unregisterShortcut",
        "prompts.validation.emptyName", "prompts.validation.explanationTooLong",
        "prompts.validation.immutableBuiltIn", "prompts.validation.invalidCustomIdentifier",
        "prompts.validation.invalidTemplate", "prompts.validation.nameTooLong",
        "prompts.validation.presetNotFound", "prompts.validation.templateTooLong",
        "manual.explanation", "manual.heading", "models.providers",
        "privacyHistory.search.explanation",
        "prompts.editor.explanationText", "prompts.editor.title",
        "result.phase.completed", "result.phase.connecting", "result.phase.failed",
        "result.phase.preparing", "result.phase.streaming", "result.phase.waiting",
        "result.backToLatest", "result.close", "result.pin",
        "result.source.collapse", "result.source.expand",
        "selection.accessibility.status.denied",
        "selection.accessibility.status.granted",
        "selection.accessibility.status.unknown",
        "settings.about.explanation", "settings.general.explanation",
        "settings.models.explanation", "settings.privacyHistory.explanation",
        "settings.prompts.explanation", "settings.selection.explanation",
        "settings.about", "settings.general", "settings.models",
        "settings.privacyHistory", "settings.prompts", "settings.selection",
        "shortcut.conflict.nextAction", "shortcut.unavailable.nextAction",
    ]

}
