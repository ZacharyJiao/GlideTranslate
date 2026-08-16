import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsWindowPresenter {
    private(set) var requestCount = 0
    private(set) var consumedRequestCount = 0

    func open() {
        requestCount &+= 1
    }

    func openPendingRequests(
        using openSettings: @MainActor () -> Void,
        activateApplication: @MainActor () -> Void
    ) {
        guard consumedRequestCount < requestCount else { return }
        consumedRequestCount = requestCount
        openSettings()
        activateApplication()
    }
}

struct SettingsWindowRequestBridge: View {
    let presenter: SettingsWindowPresenter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { openPendingRequests() }
            .onChange(of: presenter.requestCount) { _, _ in openPendingRequests() }
            .accessibilityHidden(true)
    }

    private func openPendingRequests() {
        presenter.openPendingRequests(
            using: { openSettings() },
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}
