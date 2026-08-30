import Foundation
import Observation
import SelectionCapture
import SharedSupport

@MainActor
protocol AppSceneCoordinating: AnyObject {
    var manualInputViewModel: ManualInputViewModel { get }
    func handleMenuTranslateSelectedText() async
    func setAutomaticCapturePaused(_ paused: Bool) async
    func selectDefaultPreset(_ presetID: PresetID) async
}

extension AppCoordinator: AppSceneCoordinating {}

@MainActor
@Observable
final class AppSceneState {
    let coordinator: any AppSceneCoordinating
    let manualPresenter: ManualWindowPresenter
    let settingsPresenter: SettingsWindowPresenter
    let onboardingPresenter: OnboardingWindowPresenter
    let shortcutSettingsModel: ShortcutSettingsModel
    var captureState: CaptureMenuState
    var automaticCapturePaused: Bool
    var presetName: String
    var presetNameLocalizationKey: String?
    var providerLocality: DestinationPrivacyClass
    var presetOptions: [MenuPresetOption]

    init(
        coordinator: any AppSceneCoordinating,
        manualPresenter: ManualWindowPresenter,
        settingsPresenter: SettingsWindowPresenter = SettingsWindowPresenter(),
        onboardingPresenter: OnboardingWindowPresenter = OnboardingWindowPresenter(),
        shortcutSettingsModel: ShortcutSettingsModel,
        captureState: CaptureMenuState,
        automaticCapturePaused: Bool = false,
        presetName: String,
        presetNameLocalizationKey: String? = nil,
        providerLocality: DestinationPrivacyClass,
        presetOptions: [MenuPresetOption] = []
    ) {
        self.coordinator = coordinator
        self.manualPresenter = manualPresenter
        self.settingsPresenter = settingsPresenter
        self.onboardingPresenter = onboardingPresenter
        self.shortcutSettingsModel = shortcutSettingsModel
        self.captureState = captureState
        self.automaticCapturePaused = automaticCapturePaused
        self.presetName = presetName
        self.presetNameLocalizationKey = presetNameLocalizationKey
        self.providerLocality = providerLocality
        self.presetOptions = presetOptions
    }

    var manualInputViewModel: ManualInputViewModel {
        coordinator.manualInputViewModel
    }

    var menuModel: MenuStatusModel {
        MenuStatusModel(
            state: captureState,
            shortcutText: shortcutSettingsModel.currentLabel,
            presetName: presetName,
            presetNameLocalizationKey: presetNameLocalizationKey,
            providerLocality: providerLocality,
            automaticCapturePaused: automaticCapturePaused
        )
    }

    var menuActions: MenuBarActions {
        let coordinator = coordinator
        let manualPresenter = manualPresenter
        let settingsPresenter = settingsPresenter
        return MenuBarActions(
            translateSelectedText: {
                Task { await coordinator.handleMenuTranslateSelectedText() }
            },
            setAutomaticCapturePaused: { paused in
                Task { await coordinator.setAutomaticCapturePaused(paused) }
            },
            selectPreset: { presetID in
                Task { await coordinator.selectDefaultPreset(presetID) }
            },
            openManualInput: { manualPresenter.open() },
            openSettings: { settingsPresenter.openSystemSettings() }
        )
    }

    static func development() -> Self {
        let presenter = ManualWindowPresenter()
        let coordinator = DevelopmentAppSceneCoordinator(presenter: presenter)
        let shortcut = ShortcutSettingsModel(
            registrar: DevelopmentShortcutRegistrar(),
            currentDescriptor: .defaultOptionShiftD
        )
        return Self(
            coordinator: coordinator,
            manualPresenter: presenter,
            onboardingPresenter: OnboardingWindowPresenter(),
            shortcutSettingsModel: shortcut,
            captureState: .paused,
            automaticCapturePaused: true,
            presetName: "Accurate Translation",
            presetNameLocalizationKey: "preset.accurate.name",
            providerLocality: .unresolvedOrChanged
        )
    }
}

@MainActor
private final class DevelopmentAppSceneCoordinator: AppSceneCoordinating {
    let manualInputViewModel: ManualInputViewModel
    private let presenter: ManualWindowPresenter

    init(presenter: ManualWindowPresenter) {
        self.presenter = presenter
        manualInputViewModel = ManualInputViewModel.development { _ in
            guard UITestingMode.isEnabled else { return }
            DistributedNotificationCenter.default().post(
                name: Notification.Name(
                    "com.zaryolabs.GlideTranslate.ui-testing.manual-submit-completed"
                ),
                object: nil,
                userInfo: nil
            )
        }
    }

    func handleMenuTranslateSelectedText() async { presenter.open() }
    func setAutomaticCapturePaused(_ paused: Bool) async {}
    func selectDefaultPreset(_ presetID: PresetID) async {}
}

private actor DevelopmentShortcutRegistrar: GlobalShortcutRegistering {
    func register(_ descriptor: ShortcutDescriptor) async throws {
        throw ShortcutRegistrationFailure.unavailable
    }

    func unregister() async {}
}
