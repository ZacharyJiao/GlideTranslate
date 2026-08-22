@preconcurrency import ApplicationServices
import AppKit
import Foundation
import PrivacyStorage
import SelectionCapture

@MainActor
protocol SettingsAccessibilityClient: Sendable {
    func status() -> SettingsAccessibilityStatus
    func request() -> SettingsAccessibilityStatus
    func openSystemSettings()
}

@MainActor
struct SystemSettingsAccessibilityClient: SettingsAccessibilityClient {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!

    func status() -> SettingsAccessibilityStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    func request() -> SettingsAccessibilityStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}

@MainActor
final class ProductionSettingsSelectionController: SettingsSelectionControlling {
    private let monitor: (any SelectionTriggerMonitoring)?
    private let lifecycle: (any CapturePreferenceLifecycleControlling)?
    private let preferences: (any PreferencesStore)?
    private let accessibility: any SettingsAccessibilityClient
    private var activationAllowed: Bool
    private var automaticEnabled: Bool
    private var mouseEnabled: Bool
    private var keyboardEnabled: Bool

    init(
        monitor: any SelectionTriggerMonitoring,
        accessibility: any SettingsAccessibilityClient = SystemSettingsAccessibilityClient(),
        activationAllowed: Bool = true,
        automaticEnabled: Bool = true,
        mouseEnabled: Bool,
        keyboardEnabled: Bool
    ) {
        self.monitor = monitor
        lifecycle = nil
        preferences = nil
        self.accessibility = accessibility
        self.activationAllowed = activationAllowed
        self.automaticEnabled = automaticEnabled
        self.mouseEnabled = mouseEnabled
        self.keyboardEnabled = keyboardEnabled
    }

    init(
        lifecycle: any CapturePreferenceLifecycleControlling,
        preferences: any PreferencesStore,
        accessibility: any SettingsAccessibilityClient = SystemSettingsAccessibilityClient(),
        initialSnapshot: PreferencesSnapshot
    ) {
        monitor = nil
        self.lifecycle = lifecycle
        self.preferences = preferences
        self.accessibility = accessibility
        activationAllowed = initialSnapshot.onboardingCompleted
        automaticEnabled = initialSnapshot.automaticCaptureEnabled
        mouseEnabled = initialSnapshot.mouseSelectionEnabled
        keyboardEnabled = initialSnapshot.keyboardSelectionEnabled
    }

    func setAutomaticEnabled(_ enabled: Bool) async throws {
        if lifecycle != nil {
            try await applyProduction { $0.automaticCaptureEnabled = enabled }
            return
        }
        try await apply(
            automatic: enabled,
            mouse: mouseEnabled,
            keyboard: keyboardEnabled
        )
        automaticEnabled = enabled
    }

    func setActivationAllowed(_ allowed: Bool) async throws {
        if lifecycle != nil {
            try await applyProduction { $0.onboardingCompleted = allowed }
            return
        }
        try await apply(
            automatic: automaticEnabled,
            mouse: mouseEnabled,
            keyboard: keyboardEnabled,
            activationAllowed: allowed
        )
        activationAllowed = allowed
    }

    func setMouseEnabled(_ enabled: Bool) async throws {
        if lifecycle != nil {
            try await applyProduction { $0.mouseSelectionEnabled = enabled }
            return
        }
        try await apply(automatic: automaticEnabled, mouse: enabled, keyboard: keyboardEnabled)
        mouseEnabled = enabled
    }

    func setKeyboardEnabled(_ enabled: Bool) async throws {
        if lifecycle != nil {
            try await applyProduction { $0.keyboardSelectionEnabled = enabled }
            return
        }
        try await apply(automatic: automaticEnabled, mouse: mouseEnabled, keyboard: enabled)
        keyboardEnabled = enabled
    }

    func accessibilityStatus() -> SettingsAccessibilityStatus {
        accessibility.status()
    }

    func openAccessibilitySettings() {
        accessibility.openSystemSettings()
    }

    func requestAccessibility() -> SettingsAccessibilityStatus {
        accessibility.request()
    }

    private func apply(
        automatic: Bool,
        mouse: Bool,
        keyboard: Bool,
        activationAllowed: Bool? = nil
    ) async throws {
        let allowed = activationAllowed ?? self.activationAllowed
        let effectiveMouse = allowed && automatic && mouse
        let effectiveKeyboard = allowed && automatic && keyboard
        if effectiveMouse || effectiveKeyboard {
            guard let monitor else { throw AppLifecycleTransitionFailure.inactive }
            try await monitor.start(
                mouseEnabled: effectiveMouse,
                keyboardEnabled: effectiveKeyboard
            )
        } else {
            await monitor?.stop()
        }
    }

    private func applyProduction(
        _ mutation: (inout PreferencesSnapshot) -> Void
    ) async throws {
        guard let lifecycle, let preferences else {
            throw AppLifecycleTransitionFailure.inactive
        }
        var snapshot = try await preferences.snapshot()
        mutation(&snapshot)
        try await lifecycle.applyCapturePreferences(
            onboardingCompleted: snapshot.onboardingCompleted,
            automaticCaptureEnabled: snapshot.automaticCaptureEnabled,
            mouseSelectionEnabled: snapshot.mouseSelectionEnabled,
            keyboardSelectionEnabled: snapshot.keyboardSelectionEnabled
        )
        activationAllowed = snapshot.onboardingCompleted
        automaticEnabled = snapshot.automaticCaptureEnabled
        mouseEnabled = snapshot.mouseSelectionEnabled
        keyboardEnabled = snapshot.keyboardSelectionEnabled
    }
}
