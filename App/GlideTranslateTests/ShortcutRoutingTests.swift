import SelectionCapture
import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class ShortcutRoutingTests: XCTestCase {
    private enum ShortcutRouteRow: Equatable {
        case registrationSuccess(currentLabel: String, manualOpens: Int)
        case registrationConflict(requiresReplacement: Bool, keyloggerInstalls: Int)
        case selectionAuthorized(engineCalls: Int, manualOpens: Int)
        case noSupportedSelection(engineCalls: Int, manualOpens: Int)
        case unsafeClipboardFallback(engineCalls: Int, manualOpens: Int)
        case providerChanged(engineCalls: Int, safeError: SelectionAuthorizationFailure)
        case manualSubmitAuthorized(systemReads: Int, engineCalls: Int)
        case manualSubmitRejected(systemReads: Int, engineCalls: Int)
        case manualWindowRequestedTwice(windowCount: Int)
    }

    private let rows: [ShortcutRouteRow] = [
        .registrationSuccess(currentLabel: "⌥⇧D", manualOpens: 0),
        .registrationConflict(requiresReplacement: true, keyloggerInstalls: 0),
        .selectionAuthorized(engineCalls: 1, manualOpens: 0),
        .noSupportedSelection(engineCalls: 0, manualOpens: 1),
        .unsafeClipboardFallback(engineCalls: 0, manualOpens: 1),
        .providerChanged(engineCalls: 0, safeError: .providerChanged),
        .manualSubmitAuthorized(systemReads: 0, engineCalls: 1),
        .manualSubmitRejected(systemReads: 0, engineCalls: 0),
        .manualWindowRequestedTwice(windowCount: 1),
    ]

    func testShortcutAndManualRowsDriveTheirExpectedEffects() async {
        for row in rows {
            switch row {
            case let .registrationSuccess(currentLabel, manualOpens):
                let registrar = ShortcutRegistrarFixture(results: [.success(())])
                let model = ShortcutSettingsModel(registrar: registrar)
                await model.register(.defaultOptionShiftD)
                XCTAssertEqual(model.currentLabel, currentLabel)
                XCTAssertEqual(model.manualOpenCount, manualOpens)

            case let .registrationConflict(requiresReplacement, keyloggerInstalls):
                let previous = ShortcutDescriptor.defaultOptionShiftD
                let replacement = ShortcutDescriptor(keyCode: 3, modifiers: previous.modifiers)
                let registrar = ShortcutRegistrarFixture(results: [
                    .failure(.conflict),
                    .success(()),
                ])
                let model = ShortcutSettingsModel(
                    registrar: registrar,
                    currentDescriptor: previous
                )
                await model.register(replacement)
                XCTAssertEqual(model.requiresReplacement, requiresReplacement)
                XCTAssertEqual(model.keyloggerInstallCount, keyloggerInstalls)
                XCTAssertEqual(model.currentDescriptor, previous)
                let descriptors = await registrar.registeredDescriptors()
                XCTAssertEqual(descriptors, [replacement, previous])

            case let .selectionAuthorized(engineCalls, manualOpens):
                let fixture = CoordinatorFixture()
                fixture.systemProcessor.outcome = .authorized(
                    fixture.intent(), fixture.context()
                )
                fixture.engine.updates = [.preparing]
                await fixture.coordinator.handleMenuTranslateSelectedText()
                await fixture.waitForEngineCalls(engineCalls)
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)
                XCTAssertEqual(fixture.manual.openCount, manualOpens)

            case let .noSupportedSelection(engineCalls, manualOpens):
                let fixture = CoordinatorFixture(systemOutcome: .manualInputRequired)
                await fixture.coordinator.handleMenuTranslateSelectedText()
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)
                XCTAssertEqual(fixture.manual.openCount, manualOpens)

            case let .unsafeClipboardFallback(engineCalls, manualOpens):
                let fixture = CoordinatorFixture(systemOutcome: .manualInputRequired)
                await fixture.coordinator.handleMenuTranslateSelectedText()
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)
                XCTAssertEqual(fixture.manual.openCount, manualOpens)

            case let .providerChanged(engineCalls, safeError):
                let fixture = CoordinatorFixture(systemOutcome: .rejected(safeError))
                await fixture.coordinator.handleMenuTranslateSelectedText()
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)
                XCTAssertEqual(fixture.feedback.failures, [.destinationReconfirmationRequired])

            case let .manualSubmitAuthorized(systemReads, engineCalls):
                let fixture = CoordinatorFixture()
                fixture.gate.manualOutcome = .authorized(
                    fixture.intent(), fixture.context()
                )
                fixture.engine.updates = [.preparing]
                await fixture.coordinator.submitManual(fixture.manualDraft())
                await fixture.waitForEngineCalls(engineCalls)
                XCTAssertEqual(fixture.systemProcessor.systemReads, systemReads)
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)

            case let .manualSubmitRejected(systemReads, engineCalls):
                let fixture = CoordinatorFixture()
                fixture.gate.manualOutcome = .rejected(.applicationNotAllowed)
                await fixture.coordinator.submitManual(fixture.manualDraft())
                XCTAssertEqual(fixture.systemProcessor.systemReads, systemReads)
                XCTAssertEqual(fixture.engine.translateCalls.count, engineCalls)

            case let .manualWindowRequestedTwice(windowCount):
                let presenter = ManualWindowPresenter()
                presenter.open()
                presenter.open()
                var openedSceneIDs: [String] = []
                presenter.openPendingRequests(
                    using: { openedSceneIDs.append($0) },
                    activateApplication: {}
                )
                XCTAssertEqual(Set(openedSceneIDs).count, windowCount)
            }
        }
    }

    func testUnavailableRegistrationKeepsDisplayAndProvidesSafeNextAction() async {
        let previous = ShortcutDescriptor.defaultOptionShiftD
        let replacement = ShortcutDescriptor(keyCode: 3, modifiers: previous.modifiers)
        let registrar = ShortcutRegistrarFixture(results: [
            .failure(.unavailable),
            .success(()),
        ])
        let model = ShortcutSettingsModel(
            registrar: registrar,
            currentDescriptor: previous
        )

        await model.register(replacement)

        XCTAssertEqual(model.currentDescriptor, previous)
        XCTAssertEqual(model.safeNextActionKey, "shortcut.unavailable.nextAction")
        XCTAssertFalse(model.requiresReplacement)
        XCTAssertEqual(model.keyloggerInstallCount, 0)
    }

    func testShortcutLabelUsesThePlatformModifierMasks() async {
        let descriptor = ShortcutDescriptor(
            keyCode: 2,
            modifiers: 0x0008_0000 | 0x0002_0000 | 0x0010_0000 | 0x0004_0000
        )
        let registrar = ShortcutRegistrarFixture(results: [.success(())])
        let model = ShortcutSettingsModel(registrar: registrar)

        await model.register(descriptor)

        XCTAssertEqual(model.currentLabel, "⌥⇧⌘⌃D")
    }

    func testOneAppSceneStateSharesCoordinatorManualPresenterAndShortcutLabel() async {
        let presenter = ManualWindowPresenter()
        let registrar = ShortcutRegistrarFixture(results: [.success(())])
        let shortcut = ShortcutSettingsModel(registrar: registrar)
        let coordinator = SceneCoordinatorFixture()
        let settingsPresenter = SettingsWindowPresenter()
        let state = AppSceneState(
            coordinator: coordinator,
            manualPresenter: presenter,
            settingsPresenter: settingsPresenter,
            shortcutSettingsModel: shortcut,
            captureState: .running,
            presetName: "Accurate Translation",
            providerLocality: .localOnDevice
        )

        XCTAssertTrue(state.manualPresenter === presenter)
        XCTAssertTrue(state.manualInputViewModel === coordinator.manualInputViewModel)

        await shortcut.register(.defaultOptionShiftD)
        XCTAssertEqual(state.menuModel.shortcutText, "⌥⇧D")

        state.menuActions.translateSelectedText()
        state.menuActions.setAutomaticCapturePaused(true)
        state.menuActions.selectPreset(PresetID(rawValue: "polish-expression"))
        state.menuActions.openManualInput()
        state.menuActions.openSettings()
        for _ in 0..<20 where coordinator.callCount < 3 { await Task.yield() }
        XCTAssertEqual(coordinator.translateCount, 1)
        XCTAssertEqual(coordinator.pauseValues, [true])
        XCTAssertEqual(coordinator.presetIDs, [PresetID(rawValue: "polish-expression")])
        XCTAssertEqual(presenter.requestCount, 1)
        XCTAssertEqual(settingsPresenter.systemOpenRequestCount, 1)

        state.manualInputViewModel.text = "manual"
        await state.manualInputViewModel.submit()
        XCTAssertEqual(coordinator.manualDrafts.map(\.text), ["manual"])
    }
}

private actor ShortcutRegistrarFixture: GlobalShortcutRegistering {
    private var results: [Result<Void, ShortcutRegistrationFailure>]
    private var descriptors: [ShortcutDescriptor] = []

    init(results: [Result<Void, ShortcutRegistrationFailure>]) {
        self.results = results
    }

    func register(_ descriptor: ShortcutDescriptor) async throws {
        descriptors.append(descriptor)
        guard !results.isEmpty else { return }
        try results.removeFirst().get()
    }

    func unregister() async {}

    func registeredDescriptors() -> [ShortcutDescriptor] { descriptors }
}

@MainActor
private final class SceneCoordinatorFixture: AppSceneCoordinating {
    private(set) var translateCount = 0
    private(set) var pauseValues: [Bool] = []
    private(set) var presetIDs: [PresetID] = []
    private(set) var manualDrafts: [ManualTranslationDraft] = []
    lazy var manualInputViewModel = ManualInputViewModel.development { [weak self] draft in
        self?.manualDrafts.append(draft)
    }

    var callCount: Int { translateCount + pauseValues.count + presetIDs.count }

    func handleMenuTranslateSelectedText() async { translateCount += 1 }
    func setAutomaticCapturePaused(_ paused: Bool) async { pauseValues.append(paused) }
    func selectDefaultPreset(_ presetID: PresetID) async { presetIDs.append(presetID) }
}
