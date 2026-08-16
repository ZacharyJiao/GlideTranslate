import PrivacyStorage
import SelectionCapture
import SharedSupport
import XCTest
@testable import GlideTranslate

final class AppLifecycleTests: XCTestCase {
    @MainActor
    func testStartupUsesEffectivePreferencesAndRoutesEachTriggerOnce() async throws {
        let monitor = LifecycleMonitorSpy()
        let shortcut = LifecycleShortcutSpy()
        let history = LifecycleHistorySpy()
        let requests = LifecycleRequestSpy()
        let storage = LifecycleStorageSpy()
        let caches = LifecycleCacheSpy()
        let clock = LifecycleClock()
        let routed = LifecycleTriggerRecorder()
        let controller = AppLifecycleController(
            monitor: monitor,
            shortcutRegistrar: shortcut,
            history: history,
            requests: requests,
            storageReset: storage,
            caches: caches,
            clock: clock,
            route: { trigger in await routed.record(trigger) }
        )

        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )
        await controller.route(.mouse)
        await controller.route(.keyboardSelection)
        await controller.route(.shortcut)
        try await controller.applyCapturePreferences(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: false,
            keyboardSelectionEnabled: true
        )
        await controller.route(.mouse)
        await controller.route(.keyboardSelection)

        let starts = await monitor.starts
        let values = await routed.values
        let registerCount = await shortcut.registerCount
        let maintenanceCount = await history.maintenanceCount
        XCTAssertEqual(
            starts,
            [
                .init(mouse: true, keyboard: false),
                .init(mouse: false, keyboard: true),
            ]
        )
        XCTAssertEqual(values, [.mouse, .shortcut, .keyboardSelection])
        XCTAssertEqual(registerCount, 1)
        XCTAssertEqual(maintenanceCount, 1)
        await controller.terminate()
    }

    @MainActor
    func testFullyDisabledStartupStopsMonitorAndMaintenanceFailureDoesNotBlock() async {
        let monitor = LifecycleMonitorSpy()
        let history = LifecycleHistorySpy(failMaintenance: true)
        let controller = makeController(monitor: monitor, history: history)

        await controller.start(
            automaticCaptureEnabled: false,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: true,
            shortcut: .defaultOptionShiftD
        )

        let stopCount = await monitor.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(controller.safeState, .historyMaintenanceUnavailable)
        XCTAssertTrue(controller.manualInputAvailable)
        await controller.terminate()
    }

    @MainActor
    func testTerminationIsIdempotentAndOwnsEveryResourceExactlyOnce() async {
        let monitor = LifecycleMonitorSpy()
        let shortcut = LifecycleShortcutSpy()
        let requests = LifecycleRequestSpy()
        let storage = LifecycleStorageSpy()
        let caches = LifecycleCacheSpy()
        let controller = makeController(
            monitor: monitor,
            shortcut: shortcut,
            requests: requests,
            storage: storage,
            caches: caches
        )
        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: true,
            shortcut: .defaultOptionShiftD
        )

        await controller.terminate()
        await controller.terminate()

        let cancelCount = await requests.cancelCount
        let stopCount = await monitor.stopCount
        let unregisterCount = await shortcut.unregisterCount
        let closeCount = await storage.closeCount
        let clearCount = await caches.clearCount
        let plaintextCount = await caches.plaintextCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(unregisterCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(plaintextCount, 0)
    }

    @MainActor
    func testTerminationWaitsForSuspendedPeriodicMaintenance() async {
        let history = LifecycleSuspendingHistory()
        let storage = LifecycleStorageSpy()
        let requests = LifecycleRequestSpy()
        let controller = AppLifecycleController(
            monitor: LifecycleMonitorSpy(),
            shortcutRegistrar: LifecycleShortcutSpy(),
            history: history,
            requests: requests,
            storageReset: storage,
            caches: LifecycleCacheSpy(),
            clock: LifecycleAdvancingClock(),
            route: { _ in }
        )
        await controller.start(
            automaticCaptureEnabled: false,
            mouseSelectionEnabled: false,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )
        await history.waitUntilPeriodicMaintenanceSuspended()

        let completion = LifecycleCompletionFlag()
        let termination = Task { @MainActor in
            await controller.terminate()
            await completion.markCompleted()
        }
        for _ in 0..<30 { await Task.yield() }

        let completedWhileMaintenanceSuspended = await completion.value()
        let closeCountWhileMaintenanceSuspended = await storage.closeCount
        let requestCancelCountWhileMaintenanceSuspended = await requests.cancelCount
        XCTAssertFalse(completedWhileMaintenanceSuspended)
        XCTAssertEqual(closeCountWhileMaintenanceSuspended, 0)
        XCTAssertEqual(requestCancelCountWhileMaintenanceSuspended, 0)

        await history.resumePeriodicMaintenance()
        await termination.value
        let completedAfterMaintenance = await completion.value()
        let closeCountAfterMaintenance = await storage.closeCount
        let requestCancelCountAfterMaintenance = await requests.cancelCount
        XCTAssertTrue(completedAfterMaintenance)
        XCTAssertEqual(closeCountAfterMaintenance, 1)
        XCTAssertEqual(requestCancelCountAfterMaintenance, 1)
    }

    @MainActor
    func testResetPreparationWaitsForSuspendedPeriodicMaintenance() async {
        let history = LifecycleSuspendingHistory()
        let monitor = LifecycleMonitorSpy()
        let controller = AppLifecycleController(
            monitor: monitor,
            shortcutRegistrar: LifecycleShortcutSpy(),
            history: history,
            requests: LifecycleRequestSpy(),
            storageReset: LifecycleStorageSpy(),
            caches: LifecycleCacheSpy(),
            clock: LifecycleAdvancingClock(),
            route: { _ in }
        )
        await controller.start(
            automaticCaptureEnabled: false,
            mouseSelectionEnabled: false,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )
        await history.waitUntilPeriodicMaintenanceSuspended()
        let stopCountBeforeReset = await monitor.stopCount

        let completion = LifecycleCompletionFlag()
        let preparation = Task { @MainActor in
            await controller.prepareForReset()
            await completion.markCompleted()
        }
        for _ in 0..<30 { await Task.yield() }

        let completedWhileMaintenanceSuspended = await completion.value()
        let stopCountWhileMaintenanceSuspended = await monitor.stopCount
        XCTAssertFalse(completedWhileMaintenanceSuspended)
        XCTAssertEqual(stopCountWhileMaintenanceSuspended, stopCountBeforeReset)

        await history.resumePeriodicMaintenance()
        await preparation.value
        let completedAfterMaintenance = await completion.value()
        let stopCountAfterMaintenance = await monitor.stopCount
        XCTAssertTrue(completedAfterMaintenance)
        XCTAssertEqual(stopCountAfterMaintenance, stopCountBeforeReset + 1)
        await controller.retireAfterReset()
    }

    @MainActor
    func testMaintenanceRepeatsOnlyAfterExact24HourSleepBoundary() async {
        let history = LifecycleHistorySpy()
        let clock = LifecycleAdvancingClock()
        let controller = AppLifecycleController(
            monitor: LifecycleMonitorSpy(),
            shortcutRegistrar: LifecycleShortcutSpy(),
            history: history,
            requests: LifecycleRequestSpy(),
            storageReset: LifecycleStorageSpy(),
            caches: LifecycleCacheSpy(),
            clock: clock,
            route: { _ in }
        )

        await controller.start(
            automaticCaptureEnabled: false,
            mouseSelectionEnabled: false,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )
        for _ in 0..<100 {
            if await history.maintenanceCount >= 2 { break }
            await Task.yield()
        }

        let maintenanceCount = await history.maintenanceCount
        let durations = await clock.durations
        XCTAssertEqual(maintenanceCount, 2)
        XCTAssertEqual(durations.first, .seconds(24 * 60 * 60))
        await controller.terminate()
    }

    @MainActor
    func testStartupShortcutConflictStopsCaptureAndExposesReplacementState() async {
        let monitor = LifecycleMonitorSpy()
        let registrar = LifecycleShortcutSpy(failure: .conflict)
        let model = ShortcutSettingsModel(
            registrar: registrar,
            currentDescriptor: .defaultOptionShiftD
        )
        let controller = AppLifecycleController(
            monitor: monitor,
            shortcutRegistrar: registrar,
            shortcutModel: model,
            history: LifecycleHistorySpy(),
            requests: LifecycleRequestSpy(),
            storageReset: LifecycleStorageSpy(),
            caches: LifecycleCacheSpy(),
            clock: LifecycleClock(),
            route: { _ in }
        )

        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: true,
            shortcut: .defaultOptionShiftD
        )

        XCTAssertEqual(controller.safeState, .shortcutReplacementRequired)
        XCTAssertEqual(model.state, .replacementRequired)
        let stopCount = await monitor.stopCount
        XCTAssertEqual(stopCount, 1)
        await controller.terminate()
    }

    @MainActor
    func testCloseFailureSurfacesTypedPartialShutdown() async {
        let storage = LifecycleStorageSpy(failClose: true)
        let controller = makeController(storage: storage)
        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )

        await controller.terminate()

        XCTAssertEqual(controller.safeState, .partialShutdown)
    }

    @MainActor
    func testMaintenanceFailureFailsClosedBeforeAutomaticMonitorStarts() async {
        let monitor = LifecycleMonitorSpy()
        let controller = makeController(
            monitor: monitor,
            history: LifecycleHistorySpy(failMaintenance: true)
        )

        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: true,
            shortcut: .defaultOptionShiftD
        )

        let starts = await monitor.starts
        let stopCount = await monitor.stopCount
        XCTAssertTrue(starts.isEmpty)
        XCTAssertGreaterThanOrEqual(stopCount, 1)
        XCTAssertEqual(controller.safeState, .historyMaintenanceUnavailable)
        await controller.terminate()
    }

    @MainActor
    func testPostTerminationRuntimeStateCannotRestartCapture() async {
        let monitor = LifecycleMonitorSpy()
        let controller = makeController(monitor: monitor)
        await controller.start(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )
        await controller.terminate()

        var snapshot = PreferencesSnapshot.appFixture(
            providerID: ProviderConfigurationID(rawValue: UUID())
        )
        snapshot.automaticCaptureEnabled = true
        snapshot.mouseSelectionEnabled = true
        snapshot.keyboardSelectionEnabled = true
        do {
            try await controller.applyRuntimeState(
                snapshot,
                shortcutState: .registered
            )
            XCTFail("terminated lifecycle must reject preference applications")
        } catch {
            XCTAssertEqual(error as? AppLifecycleTransitionFailure, .inactive)
        }
        let starts = await monitor.starts
        XCTAssertEqual(starts.count, 1)
    }

    @MainActor
    func testResidualPlaintextAfterClearSurfacesPartialShutdown() async {
        let controller = makeController(
            caches: LifecycleCacheSpy(residualAfterClear: 1)
        )
        await controller.start(
            automaticCaptureEnabled: false,
            mouseSelectionEnabled: false,
            keyboardSelectionEnabled: false,
            shortcut: .defaultOptionShiftD
        )

        await controller.terminate()

        XCTAssertEqual(controller.safeState, .partialShutdown)
    }

    @MainActor
    func testTerminationInvalidatesSuspendedReplacementAndWaitsForItsExit() async throws {
        let gate = ApplicationRuntimeTransitionGate()
        let replacementToken = try XCTUnwrap(gate.beginReplacement())
        let completion = LifecycleCompletionFlag()
        let waiter = Task { @MainActor in
            await gate.waitForReplacementToFinish()
            await completion.markCompleted()
        }
        await Task.yield()
        let completedBeforeTermination = await completion.value()
        XCTAssertFalse(completedBeforeTermination)

        gate.beginTermination()

        XCTAssertFalse(gate.isCurrent(replacementToken))
        XCTAssertNil(gate.beginReplacement())
        let completedWhileReplacementSuspended = await completion.value()
        XCTAssertFalse(completedWhileReplacementSuspended)

        gate.finishReplacement()
        await waiter.value
        let completedAfterFinish = await completion.value()
        XCTAssertTrue(completedAfterFinish)
    }

    @MainActor
    func testTerminationWaitsForResetStageHeldInsideRuntimeTransaction() async {
        let gate = ApplicationRuntimeTransitionGate()
        let reset = LifecycleSuspendedSettingsReset()
        let completion = LifecycleCompletionFlag()
        let transaction = Task { @MainActor in
            try? await gate.withReplacementTransaction { _ in
                await reset.resetAll()
            }
        }
        await reset.waitUntilStarted()

        gate.beginTermination()
        let terminationWaiter = Task { @MainActor in
            await gate.waitForReplacementToFinish()
            await completion.markCompleted()
        }
        await Task.yield()
        let completedWhileResetSuspended = await completion.value()
        XCTAssertFalse(completedWhileResetSuspended)

        reset.resume()
        _ = await transaction.value
        await terminationWaiter.value

        let completedAfterReset = await completion.value()
        XCTAssertTrue(completedAfterReset)
    }

    @MainActor
    private func makeController(
        monitor: LifecycleMonitorSpy = LifecycleMonitorSpy(),
        shortcut: LifecycleShortcutSpy = LifecycleShortcutSpy(),
        history: LifecycleHistorySpy = LifecycleHistorySpy(),
        requests: LifecycleRequestSpy = LifecycleRequestSpy(),
        storage: LifecycleStorageSpy = LifecycleStorageSpy(),
        caches: LifecycleCacheSpy = LifecycleCacheSpy()
    ) -> AppLifecycleController {
        AppLifecycleController(
            monitor: monitor,
            shortcutRegistrar: shortcut,
            history: history,
            requests: requests,
            storageReset: storage,
            caches: caches,
            clock: LifecycleClock(),
            route: { _ in }
        )
    }
}

@MainActor
private final class LifecycleSuspendedSettingsReset: SettingsResetting {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func resetAll() async -> ResetReport {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .completed
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LifecycleMonitorSpy: SelectionTriggerMonitoring {
    struct Start: Equatable { let mouse: Bool; let keyboard: Bool }
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    func start(mouseEnabled: Bool, keyboardEnabled: Bool) async throws {
        starts.append(.init(mouse: mouseEnabled, keyboard: keyboardEnabled))
    }
    func stop() async { stopCount += 1 }
}

private actor LifecycleShortcutSpy: GlobalShortcutRegistering {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    let failure: ShortcutRegistrationFailure?
    init(failure: ShortcutRegistrationFailure? = nil) { self.failure = failure }
    func register(_ descriptor: ShortcutDescriptor) async throws {
        registerCount += 1
        if let failure { throw failure }
    }
    func unregister() async { unregisterCount += 1 }
}

private actor LifecycleHistorySpy: SettingsHistoryManaging {
    private(set) var maintenanceCount = 0
    let failMaintenance: Bool
    init(failMaintenance: Bool = false) { self.failMaintenance = failMaintenance }
    func performMaintenance() async throws {
        maintenanceCount += 1
        if failMaintenance { throw SettingsHistoryFailure.unrecoverable }
    }
    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord] { [] }
    func delete(_ id: TranslationRecordID) async throws {}
    func clearAll() async throws {}
}

private actor LifecycleSuspendingHistory: SettingsHistoryManaging {
    private var maintenanceCount = 0
    private var periodicMaintenanceIsSuspended = false
    private var periodicContinuation: CheckedContinuation<Void, Never>?

    func performMaintenance() async throws {
        maintenanceCount += 1
        guard maintenanceCount == 2 else { return }
        periodicMaintenanceIsSuspended = true
        await withCheckedContinuation { periodicContinuation = $0 }
        periodicMaintenanceIsSuspended = false
    }

    func waitUntilPeriodicMaintenanceSuspended() async {
        while !periodicMaintenanceIsSuspended { await Task.yield() }
    }

    func resumePeriodicMaintenance() {
        periodicContinuation?.resume()
        periodicContinuation = nil
    }

    func search(_ query: HistoryQuery) async throws -> [SettingsHistoryRecord] { [] }
    func delete(_ id: TranslationRecordID) async throws {}
    func clearAll() async throws {}
}

private actor LifecycleRequestSpy: LifecycleRequestControlling {
    private(set) var cancelCount = 0
    func cancelAndDismissForTermination() async { cancelCount += 1 }
}

private actor LifecycleStorageSpy: PrivacyDataResetting {
    private(set) var closeCount = 0
    let failClose: Bool
    init(failClose: Bool = false) { self.failClose = failClose }
    func closeStores() async throws {
        closeCount += 1
        if failClose { throw SettingsHistoryFailure.unrecoverable }
    }
    func deleteHistoryStoreAndKey() async throws {}
    func deleteCustomPresetStoreAndKey() async throws {}
    func deleteProviderVaultAndCredentials() async throws {}
    func resetPreferences() async throws {}
}

private actor LifecycleCacheSpy: LifecycleCacheControlling {
    private(set) var clearCount = 0
    private(set) var plaintextCount: Int
    private let residualAfterClear: Int
    init(residualAfterClear: Int = 0) {
        self.residualAfterClear = residualAfterClear
        plaintextCount = residualAfterClear
    }
    func clearTransientState() async {
        clearCount += 1
        plaintextCount = residualAfterClear
    }
}

private actor LifecycleTriggerRecorder {
    private(set) var values: [CaptureTrigger] = []
    func record(_ trigger: CaptureTrigger) { values.append(trigger) }
}

private actor LifecycleCompletionFlag {
    private var completed = false
    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

private struct LifecycleClock: AppClock {
    var now: ContinuousClock.Instant { ContinuousClock().now }
    var date: Date { Date(timeIntervalSince1970: 0) }
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private actor LifecycleAdvancingClock: AppClock {
    nonisolated var now: ContinuousClock.Instant { ContinuousClock().now }
    nonisolated var date: Date { Date(timeIntervalSince1970: 0) }
    private(set) var durations: [Duration] = []
    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        if durations.count == 1 { return }
        try await Task.sleep(for: .seconds(3_600))
    }
}
