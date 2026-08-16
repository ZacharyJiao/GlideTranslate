import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class OnboardingWindowPresenter {
    static let sceneID = "onboarding"

    private(set) var openRequestCount = 0
    private(set) var consumedOpenRequestCount = 0
    private(set) var dismissRequestCount = 0
    private(set) var consumedDismissRequestCount = 0

    func open() {
        openRequestCount &+= 1
    }

    func dismiss() {
        dismissRequestCount &+= 1
    }

    func consumePendingRequests(
        openWindow: @MainActor (String) -> Void,
        dismissWindow: @MainActor (String) -> Void,
        activateApplication: @MainActor () -> Void
    ) {
        if consumedOpenRequestCount < openRequestCount {
            consumedOpenRequestCount = openRequestCount
            openWindow(Self.sceneID)
            activateApplication()
        }
        if consumedDismissRequestCount < dismissRequestCount {
            consumedDismissRequestCount = dismissRequestCount
            dismissWindow(Self.sceneID)
        }
    }
}

struct OnboardingWindowRequestBridge: View {
    let presenter: OnboardingWindowPresenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { consumePendingRequests() }
            .onChange(of: presenter.openRequestCount) { _, _ in
                consumePendingRequests()
            }
            .onChange(of: presenter.dismissRequestCount) { _, _ in
                consumePendingRequests()
            }
            .accessibilityHidden(true)
    }

    private func consumePendingRequests() {
        presenter.consumePendingRequests(
            openWindow: { openWindow(id: $0) },
            dismissWindow: { dismissWindow(id: $0) },
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}
