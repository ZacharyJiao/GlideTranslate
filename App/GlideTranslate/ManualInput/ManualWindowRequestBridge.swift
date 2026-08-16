import AppKit
import SwiftUI

struct ManualWindowRequestBridge: View {
    let presenter: ManualWindowPresenter
    @Environment(\.openWindow) private var openWindow
    @State private var didRequestUITestingWindow = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                requestUITestingWindowIfNeeded()
                openPendingRequests()
            }
            .onChange(of: presenter.requestCount) { _, _ in
                openPendingRequests()
            }
            .accessibilityHidden(true)
    }

    private func openPendingRequests() {
        presenter.openPendingRequests(
            using: { sceneID in openWindow(id: sceneID) },
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    private func requestUITestingWindowIfNeeded() {
        guard !didRequestUITestingWindow,
              UITestingMode.includes("--ui-testing-open-manual")
        else { return }
        didRequestUITestingWindow = true
        presenter.open()
    }
}
