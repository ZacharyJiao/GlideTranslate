import PrivacyStorage
import SelectionCapture
import SharedSupport
import OSLog

private let lifecycleRuntimeLogger = Logger(
    subsystem: "com.zaryolabs.GlideTranslate",
    category: "LifecycleRuntime"
)

protocol LifecycleRequestControlling: Sendable {
    func cancelAndDismissForTermination() async
}

protocol LifecycleCacheControlling: Sendable {
    func clearTransientState() async
    var plaintextCount: Int { get async }
}

@MainActor
protocol CapturePreferenceLifecycleControlling: Sendable {
    func applyCapturePreferences(
        onboardingCompleted: Bool,
        automaticCaptureEnabled: Bool,
        mouseSelectionEnabled: Bool,
        keyboardSelectionEnabled: Bool
    ) async throws
}

extension AppCoordinator: LifecycleRequestControlling {
    func cancelAndDismissForTermination() async {
        await terminate()
    }
}

enum AppLifecycleSafeState: Equatable, Sendable {
    case ready
    case shortcutReplacementRequired
    case shortcutUnavailable
    case historyMaintenanceUnavailable
    case captureUnavailable
    case resetting
    case partialShutdown
    case terminated
}

@MainActor
final class AppLifecycleController {
    private enum Phase { case idle, running, retiring, terminating, terminated }
    private enum ShortcutGate {
        case pending, ready, replacementRequired, unavailable
    }

    private static let maintenanceInterval: Duration = .seconds(24 * 60 * 60)

    private let monitor: any SelectionTriggerMonitoring
    private let shortcutRegistrar: any GlobalShortcutRegistering
    private let shortcutModel: ShortcutSettingsModel?
    private let history: any SettingsHistoryManaging
    private let requests: any LifecycleRequestControlling
    private let storageReset: any PrivacyDataResetting
    private let caches: any LifecycleCacheControlling
    private let clock: any AppClock
    private let routeHandler: @MainActor @Sendable (CaptureTrigger) async -> Void
    private let safeStateChanged:
        @MainActor @Sendable (AppLifecycleSafeState) -> Void
    private var maintenanceTask: Task<Void, Never>?
    private var phase: Phase = .idle
    private var shortcutGate: ShortcutGate = .pending
    private var maintenanceReady = false
    private var captureUnavailable = false
    private var partialShutdown = false
    private var onboardingCompleted = false
    private var automaticCaptureEnabled = false
    private var mouseSelectionEnabled = false
    private var keyboardSelectionEnabled = false

    var safeState: AppLifecycleSafeState {
        if partialShutdown { return .partialShutdown }
        if phase == .terminated { return .terminated }
        if phase == .retiring { return .resetting }
        switch shortcutGate {
        case .replacementRequired: return .shortcutReplacementRequired
        case .unavailable: return .shortcutUnavailable
        case .pending, .ready: break
        }
        if !maintenanceReady, phase != .idle { return .historyMaintenanceUnavailable }
        if captureUnavailable { return .captureUnavailable }
        return .ready
    }
    var manualInputAvailable: Bool {
        phase != .retiring && phase != .terminating && phase != .terminated
    }

    init(
        monitor: any SelectionTriggerMonitoring,
        shortcutRegistrar: any GlobalShortcutRegistering,
        shortcutModel: ShortcutSettingsModel? = nil,
        history: any SettingsHistoryManaging,
        requests: any LifecycleRequestControlling,
        storageReset: any PrivacyDataResetting,
        caches: any LifecycleCacheControlling,
        clock: any AppClock,
        safeStateChanged:
            @escaping @MainActor @Sendable (AppLifecycleSafeState) -> Void = { _ in },
        route: @escaping @MainActor @Sendable (CaptureTrigger) async -> Void
    ) {
        self.monitor = monitor
        self.shortcutRegistrar = shortcutRegistrar
        self.shortcutModel = shortcutModel
        self.history = history
        self.requests = requests
        self.storageReset = storageReset
        self.caches = caches
        self.clock = clock
        self.safeStateChanged = safeStateChanged
        routeHandler = route
    }

    func start(
        onboardingCompleted: Bool = true,
        automaticCaptureEnabled: Bool,
        mouseSelectionEnabled: Bool,
        keyboardSelectionEnabled: Bool,
        shortcut: ShortcutDescriptor
    ) async {
        guard phase == .idle else { return }
        lifecycleRuntimeLogger.info("Lifecycle start entered")
        phase = .running
        self.onboardingCompleted = onboardingCompleted
        self.automaticCaptureEnabled = automaticCaptureEnabled
        self.mouseSelectionEnabled = mouseSelectionEnabled
        self.keyboardSelectionEnabled = keyboardSelectionEnabled

        if onboardingCompleted {
            if let shortcutModel {
                await shortcutModel.registerInitial(shortcut)
                shortcutGate = Self.shortcutGate(shortcutModel.state)
            } else {
                do {
                    try await shortcutRegistrar.register(shortcut)
                    shortcutGate = .ready
                } catch ShortcutRegistrationFailure.conflict {
                    shortcutGate = .replacementRequired
                } catch {
                    shortcutGate = .unavailable
                }
            }
        } else {
            shortcutGate = .pending
        }

        lifecycleRuntimeLogger.info(
            "Lifecycle shortcut gate ready: \(self.shortcutGate == .ready, privacy: .public)"
        )

        await performMaintenance()
        guard phase == .running else { return }
        maintenanceTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.maintenanceInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.performMaintenance()
            }
        }
    }

    func route(_ trigger: CaptureTrigger) async {
        guard phase == .running, shortcutGate == .ready else { return }
        switch trigger {
        case .mouse:
            guard automaticCaptureIsAllowed else { return }
            guard mouseSelectionEnabled else { return }
        case .keyboardSelection:
            guard automaticCaptureIsAllowed else { return }
            guard keyboardSelectionEnabled else { return }
        case .shortcut, .manualInput:
            break
        }
        await routeHandler(trigger)
    }

    func applyCapturePreferences(
        onboardingCompleted: Bool = true,
        automaticCaptureEnabled: Bool,
        mouseSelectionEnabled: Bool,
        keyboardSelectionEnabled: Bool
    ) async throws {
        guard phase == .running else {
            throw AppLifecycleTransitionFailure.inactive
        }
        self.onboardingCompleted = onboardingCompleted
        self.automaticCaptureEnabled = automaticCaptureEnabled
        self.mouseSelectionEnabled = mouseSelectionEnabled
        self.keyboardSelectionEnabled = keyboardSelectionEnabled
        captureUnavailable = false
        do {
            try await reconcileMonitor()
            publishSafeState()
        } catch {
            publishSafeState()
            throw error
        }
    }

    func updateShortcutState(_ state: ShortcutRegistrationState) async throws {
        guard phase == .running else {
            throw AppLifecycleTransitionFailure.inactive
        }
        shortcutGate = Self.shortcutGate(state)
        do {
            try await reconcileMonitor()
            publishSafeState()
        } catch {
            publishSafeState()
            throw error
        }
    }

    func applyRuntimeState(
        _ snapshot: PreferencesSnapshot,
        shortcutState: ShortcutRegistrationState
    ) async throws {
        guard phase == .running else {
            throw AppLifecycleTransitionFailure.inactive
        }
        onboardingCompleted = snapshot.onboardingCompleted
        automaticCaptureEnabled = snapshot.automaticCaptureEnabled
        mouseSelectionEnabled = snapshot.mouseSelectionEnabled
        keyboardSelectionEnabled = snapshot.keyboardSelectionEnabled
        shortcutGate = Self.shortcutGate(shortcutState)
        captureUnavailable = false
        do {
            try await reconcileMonitor()
            publishSafeState()
        } catch {
            publishSafeState()
            throw error
        }
    }

    func retireAfterReset() async {
        guard phase == .running || phase == .retiring else { return }
        phase = .retiring
        await cancelAndDrainMaintenanceTask()
        await monitor.stop()
        publishSafeState()
        phase = .terminated
        publishSafeState()
    }

    func prepareForReset() async {
        guard phase == .running else { return }
        phase = .retiring
        await cancelAndDrainMaintenanceTask()
        publishSafeState()
        await monitor.stop()
    }

    func terminate() async {
        guard phase != .terminating, phase != .terminated else { return }
        phase = .terminating
        await cancelAndDrainMaintenanceTask()

        await requests.cancelAndDismissForTermination()
        await monitor.stop()
        await shortcutRegistrar.unregister()
        await caches.clearTransientState()
        if await caches.plaintextCount != 0 {
            partialShutdown = true
        }
        do {
            try await storageReset.closeStores()
        } catch {
            partialShutdown = true
        }
        phase = .terminated
        publishSafeState()
    }

    private func performMaintenance() async {
        guard phase == .running else { return }
        lifecycleRuntimeLogger.info("Lifecycle maintenance started")
        do {
            try await history.performMaintenance()
            maintenanceReady = true
        } catch {
            maintenanceReady = false
        }
        guard phase == .running, !Task.isCancelled else { return }
        do {
            try await reconcileMonitor()
            lifecycleRuntimeLogger.info("Lifecycle monitor reconciliation completed")
        } catch {
            lifecycleRuntimeLogger.error("Lifecycle monitor reconciliation failed")
            guard phase == .running, !Task.isCancelled else { return }
            captureUnavailable = true
            await monitor.stop()
        }
        guard phase == .running, !Task.isCancelled else { return }
        publishSafeState()
    }

    private func cancelAndDrainMaintenanceTask() async {
        guard let task = maintenanceTask else { return }
        maintenanceTask = nil
        task.cancel()
        await task.value
    }

    private var automaticCaptureIsAllowed: Bool {
        phase == .running
            && shortcutGate == .ready
            && maintenanceReady
            && onboardingCompleted
            && automaticCaptureEnabled
            && !captureUnavailable
    }

    private func reconcileMonitor() async throws {
        guard phase == .running else {
            await monitor.stop()
            return
        }
        let mouse = automaticCaptureIsAllowed && mouseSelectionEnabled
        let keyboard = automaticCaptureIsAllowed && keyboardSelectionEnabled
        if mouse || keyboard {
            do {
                try await monitor.start(mouseEnabled: mouse, keyboardEnabled: keyboard)
            } catch {
                captureUnavailable = true
                await monitor.stop()
                throw error
            }
        } else {
            await monitor.stop()
        }
    }

    private static func shortcutGate(
        _ state: ShortcutRegistrationState
    ) -> ShortcutGate {
        switch state {
        case .registered: .ready
        case .replacementRequired: .replacementRequired
        case .unregistered, .unavailable: .unavailable
        }
    }

    private func publishSafeState() {
        safeStateChanged(safeState)
    }
}

extension AppLifecycleController: CapturePreferenceLifecycleControlling {}

enum AppLifecycleTransitionFailure: Error, Equatable, Sendable {
    case inactive
}
