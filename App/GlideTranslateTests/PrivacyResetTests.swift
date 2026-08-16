import Foundation
import PrivacyStorage
import XCTest
@testable import GlideTranslate

@MainActor
final class PrivacyResetTests: XCTestCase {
    func testResetOrderIsExact() async {
        let recorder = ResetEventRecorder()
        let effects = ResetEffectsSpy(recorder: recorder)
        let storage = PrivacyDataResettingSpy(recorder: recorder)

        let report = await PrivacyResetService(
            effects: effects,
            storageReset: storage
        ).resetAll()

        let events = await recorder.events
        XCTAssertEqual(report, .completed)
        XCTAssertEqual(events, ResetStage.allCases)
    }

    func testEveryStageFailureContinuesAllSafeIndependentCleanup() async {
        for failingStage in ResetStage.allCases {
            let recorder = ResetEventRecorder()
            let effects = ResetEffectsSpy(
                recorder: recorder,
                failingStage: failingStage
            )
            let storage = PrivacyDataResettingSpy(
                recorder: recorder,
                failingStage: failingStage
            )

            let report = await PrivacyResetService(
                effects: effects,
                storageReset: storage
            ).resetAll()

            let expectedFailures: Set<ResetStage> = failingStage == .closeStores
                ? [.closeStores, .deleteHistoryStoreAndKey]
                : [failingStage]
            XCTAssertEqual(report.failedStages, expectedFailures)
            var expectedAttempts = ResetStage.allCases
            if failingStage == .closeStores {
                expectedAttempts.removeAll { $0 == .deleteHistoryStoreAndKey }
            }
            let events = await recorder.events
            XCTAssertEqual(events, expectedAttempts)
            XCTAssertFalse(String(describing: report).contains(effects.runtimeMarker))
            XCTAssertFalse(String(describing: report).contains(storage.runtimeMarker))
        }
    }

    func testSuccessfulResetLeavesNoRegisteredOrRoutedShortcut() async {
        let fixture = ProductionResetEffectsFixture()
        let storage = PrivacyDataResettingSpy(recorder: ResetEventRecorder())
        fixture.shortcut.activeReference = true

        let report = await PrivacyResetService(
            effects: fixture.effects,
            storageReset: storage
        ).resetAll()
        fixture.routingGate.routeIfEnabled { fixture.selectionReads += 1 }

        XCTAssertEqual(report, .completed)
        XCTAssertFalse(fixture.routingGate.isEnabled)
        XCTAssertFalse(fixture.shortcut.activeReference)
        XCTAssertEqual(fixture.selectionReads, 0)
        XCTAssertEqual(fixture.shortcut.registerCount, 0)
        XCTAssertEqual(fixture.shortcut.unregisterCount, 1)
    }

    func testShortcutUnregistrationFailureStillDisablesRoutingSynchronously() async {
        let fixture = ProductionResetEffectsFixture(
            shortcutFailure: SyntheticResetFailure.injected
        )
        let recorder = ResetEventRecorder()
        let storage = PrivacyDataResettingSpy(recorder: recorder)
        fixture.shortcut.activeReference = true

        let report = await PrivacyResetService(
            effects: fixture.effects,
            storageReset: storage
        ).resetAll()
        fixture.routingGate.routeIfEnabled { fixture.selectionReads += 1 }
        let storageAttempts = await recorder.events

        XCTAssertEqual(report.failedStages, [.unregisterShortcut])
        XCTAssertFalse(fixture.routingGate.isEnabled)
        XCTAssertTrue(fixture.shortcut.activeReference)
        XCTAssertEqual(fixture.selectionReads, 0)
        XCTAssertEqual(fixture.shortcut.registerCount, 0)
        XCTAssertEqual(fixture.shortcut.unregisterCount, 1)
        XCTAssertEqual(storageAttempts, [
            .closeStores,
            .deleteHistoryStoreAndKey,
            .deletePrivatePresetStoreAndKey,
            .deleteProviderVault,
            .resetPreferences
        ])
    }
}

private actor ResetEventRecorder {
    private var recorded: [ResetStage] = []

    var events: [ResetStage] { recorded }

    func append(_ stage: ResetStage) {
        recorded.append(stage)
    }
}

@MainActor
private final class ResetEffectsSpy: ResetEffects {
    let runtimeMarker = ["SENSITIVE", "_EFFECT_ERROR"].joined()
    private let recorder: ResetEventRecorder
    private let failingStage: ResetStage?

    init(
        recorder: ResetEventRecorder,
        failingStage: ResetStage? = nil
    ) {
        self.recorder = recorder
        self.failingStage = failingStage
    }

    func pauseCapture() async throws { try await attempt(.pauseCapture) }
    func cancelRequests() async throws { try await attempt(.cancelRequests) }
    func unregisterShortcut() async throws { try await attempt(.unregisterShortcut) }
    func unregisterLaunchAtLogin() async throws {
        try await attempt(.unregisterLaunchAtLogin)
    }
    func clearCaches() async throws { try await attempt(.clearCaches) }

    private func attempt(_ stage: ResetStage) async throws {
        await recorder.append(stage)
        if failingStage == stage { throw SyntheticResetFailure.injected }
    }
}

private actor PrivacyDataResettingSpy: PrivacyDataResetting {
    nonisolated let runtimeMarker = ["SENSITIVE", "_STORAGE_ERROR"].joined()
    private let recorder: ResetEventRecorder
    private let failingStage: ResetStage?

    init(
        recorder: ResetEventRecorder,
        failingStage: ResetStage? = nil
    ) {
        self.recorder = recorder
        self.failingStage = failingStage
    }

    func closeStores() async throws { try await attempt(.closeStores) }
    func deleteHistoryStoreAndKey() async throws {
        try await attempt(.deleteHistoryStoreAndKey)
    }
    func deleteCustomPresetStoreAndKey() async throws {
        try await attempt(.deletePrivatePresetStoreAndKey)
    }
    func deleteProviderVaultAndCredentials() async throws {
        try await attempt(.deleteProviderVault)
    }
    func resetPreferences() async throws { try await attempt(.resetPreferences) }

    private func attempt(_ stage: ResetStage) async throws {
        await recorder.append(stage)
        if failingStage == stage { throw SyntheticResetFailure.injected }
    }
}

private enum SyntheticResetFailure: Error, Equatable {
    case injected
}

@MainActor
private final class ProductionResetEffectsFixture {
    let routingGate = ShortcutRoutingGate(enabled: true)
    let shortcut: ShortcutResetRegistrarSpy
    var selectionReads = 0
    let effects: ProductionResetEffects

    init(shortcutFailure: SyntheticResetFailure? = nil) {
        shortcut = ShortcutResetRegistrarSpy(failure: shortcutFailure)
        effects = ProductionResetEffects(
            capture: NoOpCaptureResetController(),
            requests: NoOpRequestResetController(),
            routingGate: routingGate,
            shortcutRegistrar: shortcut,
            launchAtLogin: NoOpLaunchAtLoginResetController(),
            caches: NoOpCacheResetController()
        )
    }
}

@MainActor
private final class ShortcutResetRegistrarSpy: ShortcutResetRegistering {
    var activeReference = false
    private(set) var unregisterCount = 0
    private(set) var registerCount = 0
    private let failure: SyntheticResetFailure?

    init(failure: SyntheticResetFailure?) {
        self.failure = failure
    }

    func unregisterForReset() async throws {
        unregisterCount += 1
        if let failure { throw failure }
        activeReference = false
    }
}

@MainActor
private final class NoOpCaptureResetController: CaptureResetControlling {
    func pauseForReset() async throws {}
}

@MainActor
private final class NoOpRequestResetController: RequestResetControlling {
    func cancelForReset() async throws {}
}

@MainActor
private final class NoOpLaunchAtLoginResetController:
    LaunchAtLoginResetControlling {
    func unregisterForReset() async throws {}
}

@MainActor
private final class NoOpCacheResetController: CacheResetControlling {
    func clearForReset() async throws {}
}
