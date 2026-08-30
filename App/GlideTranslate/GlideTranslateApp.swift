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
                Label {
                    Text("app.name")
                } icon: {
                    MenuBarStatusGlyph(model: root.sceneState.menuModel)
                }
                    .accessibilityIdentifier("menu-bar-status-item")
                    .accessibilityLabel(root.sceneState.menuModel.stateTextKey)
                    .background(
                        ZStack {
                            ManualWindowRequestBridge(
                                presenter: root.sceneState.manualPresenter
                            )
                            OnboardingWindowRequestBridge(
                                presenter: root.sceneState.onboardingPresenter
                            )
                            MenuCommandCenterTestingBridge()
                        }
                    )
            } unavailable: { _ in
                Label("app.name", systemImage: "hourglass")
                    .accessibilityIdentifier("menu-bar-status-item")
            }
        }
        .menuBarExtraStyle(.window)
        .environment(\.locale, AppUILocaleState.shared.current)

        Window("app.name", id: "menu-command-center-testing") {
            if UITestingMode.includes("--ui-testing-command-center") {
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
            } else {
                EmptyView()
            }
        }
        .defaultSize(
            width: MenuBarCommandCenterContract.contentWidth,
            height: MenuBarCommandCenterContract.maximumHeight
        )
        .windowResizability(.contentSize)

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
        .defaultSize(width: 620, height: 480)
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
        .defaultSize(width: 640, height: 520)
        .environment(\.locale, AppUILocaleState.shared.current)

        Settings {
            ObservedProductionRoot(appDelegate: appDelegate) { root in
                SettingsRootView(viewModel: root.settingsViewModel)
                    .environment(\.locale, root.settingsViewModel.uiLocale)
            } unavailable: { delegate in
                ProductionStartupContent(delegate: delegate)
            }
        }
        .defaultSize(width: 820, height: 620)
        .environment(\.locale, AppUILocaleState.shared.current)
    }
}

private struct MenuBarStatusGlyph: View {
    let model: MenuStatusModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("MenuBarTemplate")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            if let badge = model.menuBarBadgeSymbol {
                Image(systemName: badge)
                    .font(.system(size: 6, weight: .bold))
                    .padding(1)
                    .background(.bar, in: Circle())
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct MenuCommandCenterTestingBridge: View {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpen = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !didOpen,
                      UITestingMode.includes("--ui-testing-command-center")
                else { return }
                didOpen = true
                openWindow(id: "menu-command-center-testing")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityHidden(true)
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
