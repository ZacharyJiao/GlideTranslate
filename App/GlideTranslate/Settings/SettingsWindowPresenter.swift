import AppKit
import Observation
import SwiftUI

@MainActor
protocol SettingsWindowDisplaying: AnyObject {
    func present()
}

@MainActor
private final class AppKitSettingsWindow: NSObject, SettingsWindowDisplaying, NSWindowDelegate {
    private let controller: NSWindowController
    private var restoresAccessoryPolicy = false

    init(rootView: AnyView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "menu.settings")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        controller = NSWindowController(window: window)
        super.init()
        window.delegate = self
    }

    func present() {
        if NSApp.activationPolicy() == .accessory {
            restoresAccessoryPolicy = NSApp.setActivationPolicy(.regular)
        }
        NSApp.unhide(nil)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard restoresAccessoryPolicy else { return }
        restoresAccessoryPolicy = false
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
@Observable
final class SettingsWindowPresenter {
    typealias WindowFactory = @MainActor (AnyView) -> any SettingsWindowDisplaying

    private(set) var requestCount = 0
    private(set) var systemOpenRequestCount = 0
    @ObservationIgnored private let windowFactory: WindowFactory
    @ObservationIgnored private var contentFactory: (@MainActor () -> AnyView)?
    @ObservationIgnored private var settingsWindow: (any SettingsWindowDisplaying)?

    init(windowFactory: @escaping WindowFactory = { AppKitSettingsWindow(rootView: $0) }) {
        self.windowFactory = windowFactory
    }

    func installContent(_ contentFactory: @escaping @MainActor () -> AnyView) {
        self.contentFactory = contentFactory
    }

    func open() {
        requestCount &+= 1
        presentInstalledWindow()
    }

    func openSystemSettings() {
        systemOpenRequestCount &+= 1
        presentInstalledWindow()
    }

    private func presentInstalledWindow() {
        guard contentFactory != nil else { return }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.presentInstalledWindowNow()
            }
        }
    }

    private func presentInstalledWindowNow() {
        if settingsWindow == nil, let contentFactory {
            settingsWindow = windowFactory(contentFactory())
        }
        settingsWindow?.present()
    }
}
