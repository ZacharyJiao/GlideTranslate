import SharedSupport

public struct PreferencesSnapshot: Codable, Equatable, Sendable {
    public var uiLanguage: ApplicationLanguage
    public var defaultTargetLanguage: LanguageChoice
    public var onboardingCompleted: Bool
    public var automaticCaptureEnabled: Bool
    public var generalAutomaticApplications: Set<ApplicationIdentity>
    public var mouseSelectionEnabled: Bool
    public var keyboardSelectionEnabled: Bool
    public var clipboardFallbackEnabled: Bool
    public var historyEnabled: Bool
    public var historyRetentionDays: Int
    public var historyMaximumCount: Int
    public var selectionDebounceMilliseconds: Int
    public var selectionCharacterLimit: Int
    public var connectionTimeoutSeconds: Int
    public var firstTokenTimeoutSeconds: Int
    public var streamIdleTimeoutSeconds: Int
    public var launchAtLogin: Bool
    public var shortcut: ShortcutDescriptor
    public var defaultPresetID: PresetID
    public var defaultProviderID: ProviderConfigurationID?
    public var historyExcludedApplications: Set<ApplicationIdentity>
}

package extension PreferencesSnapshot {
    static let defaultValue = PreferencesSnapshot(
        uiLanguage: .english,
        defaultTargetLanguage: .automatic,
        onboardingCompleted: false,
        automaticCaptureEnabled: false,
        generalAutomaticApplications: [],
        mouseSelectionEnabled: false,
        keyboardSelectionEnabled: false,
        clipboardFallbackEnabled: false,
        historyEnabled: false,
        historyRetentionDays: 30,
        historyMaximumCount: 1_000,
        selectionDebounceMilliseconds: 350,
        selectionCharacterLimit: 2_000,
        connectionTimeoutSeconds: 5,
        firstTokenTimeoutSeconds: 120,
        streamIdleTimeoutSeconds: 30,
        launchAtLogin: false,
        shortcut: .defaultOptionShiftD,
        defaultPresetID: PresetID(rawValue: "accurate-translation"),
        defaultProviderID: nil,
        historyExcludedApplications: []
    )

    func validated() throws -> Self {
        guard (100...2_000).contains(selectionDebounceMilliseconds),
              (1...20_000).contains(selectionCharacterLimit),
              (1...365).contains(historyRetentionDays),
              (1...10_000).contains(historyMaximumCount),
              (1...60).contains(connectionTimeoutSeconds),
              (5...600).contains(firstTokenTimeoutSeconds),
              (5...120).contains(streamIdleTimeoutSeconds),
              PrivacyStorageResourceLimits.validateApplications(
                  generalAutomaticApplications
              ),
              PrivacyStorageResourceLimits.validateApplications(
                  historyExcludedApplications
              ) else {
            throw SanitizedFailure.preferencesUnrecoverable
        }
        return self
    }
}
