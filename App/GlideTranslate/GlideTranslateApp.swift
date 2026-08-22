import AppKit
import SwiftUI

@main
struct GlideTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                MenuBarContent(
                    model: root.sceneState.menuModel,
                    presetOptions: root.sceneState.presetOptions,
                    actions: root.sceneState.menuActions
                )
                .environment(\.locale, root.settingsViewModel.uiLocale)
            } unavailable: { delegate in
                ProductionStartupContent(delegate: delegate)
            }
        } label: {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                Label("app.name", systemImage: root.sceneState.menuModel.stateSymbol)
                    .background(
                        ZStack {
                            ManualWindowRequestBridge(
                                presenter: root.sceneState.manualPresenter
                            )
                            OnboardingWindowRequestBridge(
                                presenter: root.sceneState.onboardingPresenter
                            )
                        }
                    )
            } unavailable: { _ in
                Label("app.name", systemImage: "hourglass")
            }
        }
        .menuBarExtraStyle(.menu)
        .environment(\.locale, AppUILocaleState.shared.current)

        Window("manual.title", id: "manual-input") {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                ManualInputView(
                    viewModel: root.sceneState.manualInputViewModel,
                    presenter: root.sceneState.manualPresenter
                )
                    .environment(\.locale, root.settingsViewModel.uiLocale)
            } unavailable: { delegate in
                ProductionStartupContent(delegate: delegate)
            }
        }
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentMinSize)
        .environment(\.locale, AppUILocaleState.shared.current)

        Window("onboarding.title", id: "onboarding") {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                if let onboarding = root.onboardingCoordinator {
                    OnboardingView(coordinator: onboarding)
                        .environment(\.locale, root.settingsViewModel.uiLocale)
                } else {
                    EmptyView()
                }
            } unavailable: { delegate in
                ProductionStartupContent(delegate: delegate)
            }
        }
        .defaultSize(width: 620, height: 480)
        .environment(\.locale, AppUILocaleState.shared.current)

        Settings {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                SettingsRootView(viewModel: root.settingsViewModel)
                    .environment(\.locale, root.settingsViewModel.uiLocale)
            } unavailable: { delegate in
                ProductionStartupContent(delegate: delegate)
            }
        }
        .defaultSize(width: 760, height: 560)
        .environment(\.locale, AppUILocaleState.shared.current)
    }
}

struct ObservedProductionRoot<Ready: View, Unavailable: View>: View {
    @ObservedObject private var appDelegate: AppDelegate
    private let ready: (ProductionCompositionRoot) -> Ready
    private let unavailable: (AppDelegate) -> Unavailable

    init(
        appDelegate: AppDelegate,
        @ViewBuilder ready: @escaping (ProductionCompositionRoot) -> Ready,
        @ViewBuilder unavailable: @escaping (AppDelegate) -> Unavailable
    ) {
        _appDelegate = ObservedObject(wrappedValue: appDelegate)
        self.ready = ready
        self.unavailable = unavailable
    }

    @ViewBuilder
    var body: some View {
        if let root = appDelegate.composition {
            ready(root)
        } else {
            unavailable(appDelegate)
        }
    }
}

private struct ProductionStartupContent: View {
    @ObservedObject var delegate: AppDelegate

    @ViewBuilder
    var body: some View {
        switch delegate.startupState {
        case .idle, .loading:
            ProgressView("app.startup.loading")
                .padding()
        case .ready:
            EmptyView()
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 8) {
                Label("app.startup.failed", systemImage: "exclamationmark.triangle")
                Group {
                    if let resetFailure = delegate.resetFailurePresentation {
                        Text("error.settings.runtimeRefreshUnavailable.message")
                        Text(LocalizedStringKey(resetFailure.runtimeFailure.localizationKey))
                        Divider()
                        Text("privacyHistory.reset.report")
                        if resetFailure.report.failedStages.isEmpty {
                            Text("privacyHistory.reset.completed")
                        } else {
                            ForEach(
                                resetFailure.failedStageLocalizationKeys,
                                id: \.self
                            ) { key in
                                Text(LocalizedStringKey(key))
                            }
                        }
                    } else {
                        Text(LocalizedStringKey(failure.localizationKey))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

private extension ProductionCompositionFailure {
    var localizationKey: String {
        switch self {
        case .corruptPreferences: "app.startup.failure.corruptPreferences"
        case .providerVaultRecoveryRequired:
            "app.startup.failure.providerVaultRecoveryRequired"
        case .shortcutConflict: "app.startup.failure.shortcutConflict"
        case .historyMaintenanceFailure:
            "app.startup.failure.historyMaintenanceFailure"
        case .captureUnavailable:
            "app.startup.failure.captureUnavailable"
        case .partialShutdown: "app.startup.failure.partialShutdown"
        }
    }
}
