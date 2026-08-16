import Foundation

@MainActor
protocol CaptureResetControlling: AnyObject {
    func pauseForReset() async throws
}

@MainActor
protocol RequestResetControlling: AnyObject {
    func cancelForReset() async throws
}

@MainActor
protocol ShortcutResetRegistering: AnyObject {
    func unregisterForReset() async throws
}

@MainActor
protocol LaunchAtLoginResetControlling: AnyObject {
    func unregisterForReset() async throws
}

@MainActor
protocol CacheResetControlling: AnyObject {
    func clearForReset() async throws
}

final class ShortcutRoutingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func disable() {
        lock.withLock { enabled = false }
    }

    func routeIfEnabled(_ operation: () -> Void) {
        lock.withLock {
            guard enabled else { return }
            operation()
        }
    }
}

@MainActor
final class ProductionResetEffects: ResetEffects {
    private let capture: any CaptureResetControlling
    private let requests: any RequestResetControlling
    private let routingGate: ShortcutRoutingGate
    private let shortcutRegistrar: any ShortcutResetRegistering
    private let launchAtLogin: any LaunchAtLoginResetControlling
    private let caches: any CacheResetControlling

    init(
        capture: any CaptureResetControlling,
        requests: any RequestResetControlling,
        routingGate: ShortcutRoutingGate,
        shortcutRegistrar: any ShortcutResetRegistering,
        launchAtLogin: any LaunchAtLoginResetControlling,
        caches: any CacheResetControlling
    ) {
        self.capture = capture
        self.requests = requests
        self.routingGate = routingGate
        self.shortcutRegistrar = shortcutRegistrar
        self.launchAtLogin = launchAtLogin
        self.caches = caches
    }

    func pauseCapture() async throws {
        try await capture.pauseForReset()
    }

    func cancelRequests() async throws {
        try await requests.cancelForReset()
    }

    func unregisterShortcut() async throws {
        routingGate.disable()
        try await shortcutRegistrar.unregisterForReset()
    }

    func unregisterLaunchAtLogin() async throws {
        try await launchAtLogin.unregisterForReset()
    }

    func clearCaches() async throws {
        try await caches.clearForReset()
    }
}
