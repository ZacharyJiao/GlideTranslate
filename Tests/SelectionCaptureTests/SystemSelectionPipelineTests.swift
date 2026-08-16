import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class SystemSelectionPipelineTests: XCTestCase {
    private actor StubPipelineGate: ResettableSelectionAuthorizationGate {
        private(set) var calls = 0
        private(set) var resets = 0

        func authorizeSystemSelection(
            trigger: CaptureTrigger,
            context: ForegroundApplicationContext,
            options: TranslationOptionsSnapshot,
            policy: CapturePolicySnapshot,
            provider: ProviderDestinationSnapshot
        ) async -> SelectionAuthorizationOutcome {
            calls += 1
            return .manualInputRequired
        }

        func authorizeManualSubmission(
            _ submission: ManualTranslationSubmission,
            policy: SendPolicySnapshot,
            provider: ProviderDestinationSnapshot
        ) async -> SelectionAuthorizationOutcome {
            .manualInputRequired
        }

        func resetDuplicateState() { resets += 1 }
    }

    private actor SuspendingResetGate: ResettableSelectionAuthorizationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var resetStarted = false
        private(set) var providers: [ProviderConfigurationID] = []

        func authorizeSystemSelection(
            trigger: CaptureTrigger,
            context: ForegroundApplicationContext,
            options: TranslationOptionsSnapshot,
            policy: CapturePolicySnapshot,
            provider: ProviderDestinationSnapshot
        ) async -> SelectionAuthorizationOutcome {
            providers.append(provider.configurationID)
            return .manualInputRequired
        }

        func authorizeManualSubmission(
            _ submission: ManualTranslationSubmission,
            policy: SendPolicySnapshot,
            provider: ProviderDestinationSnapshot
        ) async -> SelectionAuthorizationOutcome {
            .manualInputRequired
        }

        func resetDuplicateState() async {
            resetStarted = true
            await withCheckedContinuation { continuation = $0 }
        }

        func resumeReset() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testMouseDebouncesBeforeResolvingForeground() async {
        let fixture = AuthorizationFixture()
        let clock = ManualAppClock()
        let gate = StubPipelineGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .milliseconds(350),
                clock: clock
            )
        )
        let task = Task {
            await pipeline.process(
                trigger: .mouse,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(349))
        XCTAssertEqual(fixture.foregroundReader.count.value, 0)
        await clock.advance(by: .milliseconds(1))
        let outcome = await task.value
        let gateCalls = await gate.calls
        XCTAssertTrue(outcome.isManualInputRequired)
        XCTAssertEqual(fixture.foregroundReader.count.value, 1)
        XCTAssertEqual(gateCalls, 1)
    }

    func testNewMouseEventCancelsOlderPipelineRequest() async {
        let fixture = AuthorizationFixture()
        let clock = ManualAppClock()
        let gate = StubPipelineGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(delay: .milliseconds(350), clock: clock)
        )
        let first = Task {
            await pipeline.process(
                trigger: .mouse,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        await clock.waitForSleepers(1)
        let second = Task {
            await pipeline.process(
                trigger: .mouse,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        await clock.waitForSleepers(2)
        await clock.advance(by: .milliseconds(350))
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let gateCalls = await gate.calls
        XCTAssertEqual(firstOutcome.failure, .cancelled)
        XCTAssertTrue(secondOutcome.isManualInputRequired)
        XCTAssertEqual(gateCalls, 1)
    }

    func testNewerMouseWinsBeforeSuspendingDuplicateReset() async {
        let fixture = AuthorizationFixture()
        let clock = ManualAppClock()
        let gate = SuspendingResetGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .milliseconds(350),
                clock: clock
            )
        )
        let olderProvider = fixture.expected
        let newerProvider = ProviderDestinationSnapshot.fixture(
            configurationID: ProviderConfigurationID()
        )
        let older = Task {
            await pipeline.process(
                trigger: .mouse,
                options: fixture.options,
                policy: fixture.policy,
                provider: olderProvider
            )
        }
        await clock.waitForSleepers(1)
        let newer = Task {
            await pipeline.process(
                trigger: .mouse,
                options: fixture.options,
                policy: fixture.policy,
                provider: newerProvider
            )
        }
        await clock.waitForSleepers(2)
        await clock.advance(by: .milliseconds(350))
        while !(await gate.resetStarted) { await Task.yield() }
        let olderOutcome = await older.value
        XCTAssertEqual(olderOutcome.failure, .cancelled)
        await gate.resumeReset()
        let newerOutcome = await newer.value
        let providers = await gate.providers
        XCTAssertTrue(newerOutcome.isManualInputRequired)
        XCTAssertEqual(providers, [newerProvider.configurationID])
    }

    func testShortcutBypassesDebounceAndManualTriggerUsesNoForeground() async {
        let fixture = AuthorizationFixture()
        let gate = StubPipelineGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .milliseconds(350),
                clock: ManualAppClock()
            )
        )
        let shortcut = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(shortcut.isManualInputRequired)
        XCTAssertEqual(fixture.foregroundReader.count.value, 1)
        let manual = await pipeline.process(
            trigger: .manualInput,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(manual.isManualInputRequired)
        XCTAssertEqual(fixture.foregroundReader.count.value, 1)
    }

    func testPauseAllowlistOrActiveProviderChangesResetDuplicateState() async {
        let fixture = AuthorizationFixture()
        let gate = StubPipelineGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(delay: .zero, clock: ManualAppClock())
        )
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        let resetsBeforeChange = await gate.resets
        XCTAssertEqual(resetsBeforeChange, 1)
        let paused = copiedPolicy(
            fixture.policy,
            automaticCaptureEnabled: false
        )
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: paused,
            provider: fixture.expected
        )
        let resetsAfterChange = await gate.resets
        XCTAssertEqual(resetsAfterChange, 2)

        let changedAllowlist = copiedPolicy(
            paused,
            generalAllowlist: []
        )
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: changedAllowlist,
            provider: fixture.expected
        )
        let resetsAfterAllowlist = await gate.resets
        XCTAssertEqual(resetsAfterAllowlist, 3)

        let changedProvider = ProviderDestinationSnapshot.fixture(
            configurationID: ProviderConfigurationID()
        )
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: changedAllowlist,
            provider: changedProvider
        )
        let resetsAfterProvider = await gate.resets
        XCTAssertEqual(resetsAfterProvider, 4)
    }

    func testUnrelatedPolicyAndProviderSnapshotChangesDoNotResetDuplicates() async {
        let fixture = AuthorizationFixture()
        let gate = StubPipelineGate()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(delay: .zero, clock: ManualAppClock())
        )
        let unrelatedPolicies = [
            copiedPolicy(fixture.policy, mouseSelectionEnabled: false),
            copiedPolicy(fixture.policy, keyboardSelectionEnabled: true),
            copiedPolicy(fixture.policy, clipboardFallbackEnabled: true),
            copiedPolicy(fixture.policy, selectionDebounceMilliseconds: 700),
            copiedPolicy(fixture.policy, selectionCharacterLimit: 1_000)
        ]
        _ = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        for policy in unrelatedPolicies {
            _ = await pipeline.process(
                trigger: .shortcut,
                options: fixture.options,
                policy: policy,
                provider: fixture.expected.changing(.configurationRevision)
            )
        }
        let resets = await gate.resets
        XCTAssertEqual(resets, 1)
    }

    func testFactoryReturnsOnlyPublicFacadesAndBothAreCallable() async {
        let fixture = AuthorizationFixture()
        let services = SelectionCaptureFactory.makeAuthorizationServices(
            snapshotReader: fixture.snapshotReader,
            clock: ManualAppClock()
        )
        let system = await services.systemSelectionProcessor.process(
            trigger: .manualInput,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(system.isManualInputRequired)
        let submission = ManualTranslationSubmission(
            text: "synthetic manual text",
            options: fixture.options,
            providerConfigurationID: fixture.expected.configurationID
        )
        let manual = await services.authorizationGate.authorizeManualSubmission(
            submission,
            policy: .init(expectedProvider: fixture.expected),
            provider: fixture.expected
        )
        XCTAssertTrue(manual.isAuthorized)
    }

    func testEveryFilterAndDuplicateRejectionStopsBeforeSnapshotAndMint() async {
        let rejected = [
            "",
            " \n\t ",
            "12345",
            "!",
            String(repeating: "a", count: 2_001)
        ]
        for raw in rejected {
            let fixture = AuthorizationFixture()
            fixture.systemReader.result = .success(CapturedSelection(
                text: raw,
                displayRect: nil
            ))
            let gate = makeProductionGate(fixture)
            let pipeline = makeImmediatePipeline(fixture, gate: gate)
            let outcome = await pipeline.process(
                trigger: .shortcut,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
            XCTAssertEqual(outcome.failure, .noValidSelection)
            XCTAssertEqual(fixture.snapshotReader.count.value, 0)
            XCTAssertEqual(fixture.mintSpy.count.value, 0)
        }

        let fixture = AuthorizationFixture()
        let gate = makeProductionGate(fixture)
        let pipeline = makeImmediatePipeline(fixture, gate: gate)
        let first = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        let duplicate = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(first.isAuthorized)
        XCTAssertEqual(duplicate.failure, .noValidSelection)
        XCTAssertEqual(fixture.snapshotReader.count.value, 1)
        XCTAssertEqual(fixture.mintSpy.count.value, 1)
    }

    func testProviderChangeCancelsReservationAndAllowsRetry() async {
        let fixture = AuthorizationFixture()
        let gate = makeProductionGate(fixture)
        let pipeline = makeImmediatePipeline(fixture, gate: gate)
        fixture.snapshotReader.result = .success(
            fixture.expected.changing(.configurationRevision)
        )
        let rejected = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertEqual(rejected.failure, .providerChanged)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)

        fixture.snapshotReader.result = .success(fixture.expected)
        let retry = await pipeline.process(
            trigger: .shortcut,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(retry.isAuthorized)
        XCTAssertEqual(fixture.snapshotReader.count.value, 2)
        XCTAssertEqual(fixture.mintSpy.count.value, 1)
    }

    private func makeProductionGate(
        _ fixture: AuthorizationFixture
    ) -> DefaultSelectionAuthorizationGate {
        DefaultSelectionAuthorizationGate(
            foregroundReader: fixture.foregroundReader,
            systemReader: fixture.systemReader,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: fixture.snapshotReader,
            selectionFilter: SelectionFilter(limit: 2_000),
            duplicateChecker: DuplicateSuppressor(),
            mintObserver: fixture.mintSpy
        )
    }

    private func makeImmediatePipeline(
        _ fixture: AuthorizationFixture,
        gate: DefaultSelectionAuthorizationGate
    ) -> SystemSelectionPipeline {
        SystemSelectionPipeline(
            foregroundReader: fixture.foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .zero,
                clock: ManualAppClock()
            )
        )
    }


    private func copiedPolicy(
        _ policy: CapturePolicySnapshot,
        automaticCaptureEnabled: Bool? = nil,
        mouseSelectionEnabled: Bool? = nil,
        keyboardSelectionEnabled: Bool? = nil,
        generalAllowlist: Set<ApplicationIdentity>? = nil,
        offDeviceAllowlist: Set<ApplicationIdentity>? = nil,
        clipboardFallbackEnabled: Bool? = nil,
        selectionDebounceMilliseconds: Int? = nil,
        selectionCharacterLimit: Int? = nil
    ) -> CapturePolicySnapshot {
        CapturePolicySnapshot(
            automaticCaptureEnabled:
                automaticCaptureEnabled ?? policy.automaticCaptureEnabled,
            mouseSelectionEnabled:
                mouseSelectionEnabled ?? policy.mouseSelectionEnabled,
            keyboardSelectionEnabled:
                keyboardSelectionEnabled ?? policy.keyboardSelectionEnabled,
            generalAllowlist: generalAllowlist ?? policy.generalAllowlist,
            offDeviceAllowlist: offDeviceAllowlist ?? policy.offDeviceAllowlist,
            clipboardFallbackEnabled:
                clipboardFallbackEnabled ?? policy.clipboardFallbackEnabled,
            selectionDebounceMilliseconds:
                selectionDebounceMilliseconds
                    ?? policy.selectionDebounceMilliseconds,
            selectionCharacterLimit:
                selectionCharacterLimit ?? policy.selectionCharacterLimit
        )
    }
}
