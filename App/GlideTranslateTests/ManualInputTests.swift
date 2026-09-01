import SharedSupport
import SwiftUI
import XCTest

@testable import GlideTranslate

@MainActor
final class ManualInputTests: XCTestCase {
    func testManualInputStacksControlsAtTheDefaultWindowWidth() {
        XCTAssertEqual(
            ManualInputLayout.presentation(availableWidth: 620),
            .stacked
        )
        XCTAssertEqual(
            ManualInputLayout.presentation(availableWidth: 900),
            .wide
        )
    }

    func testOrdinaryManualSessionsResetToCurrentDefaultWithoutFallback() {
        let defaultID = ProviderConfigurationID()
        let overrideID = ProviderConfigurationID()
        let options = [
            ManualProviderOption(
                id: defaultID.rawValue.uuidString,
                configurationID: defaultID,
                label: "Default",
                model: "default-model",
                locality: .localOnDevice,
                isDefault: true
            ),
            ManualProviderOption(
                id: overrideID.rawValue.uuidString,
                configurationID: overrideID,
                label: "Override",
                model: "override-model",
                locality: .localNetwork
            ),
        ]
        let model = makeModel(text: "manual", providerOptions: options) { _ in }

        model.prepareForOrdinarySession(defaultProviderID: defaultID)
        XCTAssertEqual(model.selectedProviderID, options[0].id)
        model.selectedProviderID = options[1].id

        model.replaceOptions(
            source: model.sourceOptions,
            target: model.targetOptions,
            presets: model.presetOptions,
            providers: options,
            preferredSource: model.selectedSourceLanguage,
            preferredTarget: model.selectedTargetLanguage,
            preferredPresetID: model.selectedPresetID,
            preferredProviderID: overrideID
        )
        XCTAssertEqual(model.selectedProviderID, options[1].id)

        model.prepareForOrdinarySession(defaultProviderID: defaultID)
        XCTAssertEqual(model.selectedProviderID, options[0].id)

        model.prepareForOrdinarySession(defaultProviderID: ProviderConfigurationID())
        XCTAssertNil(model.selectedProviderID)
        model.prepareForOrdinarySession(defaultProviderID: nil)
        XCTAssertNil(model.selectedProviderID)
    }

    func testManualProviderOptionExposesModelReadinessCredentialAndDefaultRoute() {
        let providerID = ProviderConfigurationID()
        let option = ManualProviderOption(
            id: providerID.rawValue.uuidString,
            configurationID: providerID,
            label: "OpenAI-compatible",
            model: "k3",
            locality: .unresolvedOrChanged,
            hasCredential: true,
            isDefault: true
        )
        let model = makeModel(text: "manual", providerOptions: [option]) { _ in }

        XCTAssertEqual(model.selectedProvider?.model, "k3")
        XCTAssertEqual(
            model.selectedProvider?.readiness,
            .destinationConfirmationRequired
        )
        XCTAssertTrue(model.selectedProvider?.hasCredential == true)
        XCTAssertTrue(model.selectedProvider?.isDefault == true)
    }

    func testManualSubmitRequiresTrimmedTextAndSelections() async {
        let rows: [(String, Bool)] = [
            ("", false),
            (" \n", false),
            ("hello", true),
            (" 你好 ", true),
            (String(repeating: "a", count: 20_001), false),
        ]

        for row in rows {
            var drafts: [ManualTranslationDraft] = []
            let model = makeModel(text: row.0) { drafts.append($0) }
            await model.submit()
            XCTAssertEqual(drafts.count, row.1 ? 1 : 0, "text: \(row.0.prefix(24))")
            if let draft = drafts.first {
                XCTAssertEqual(draft.text, row.0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func testManualInputAllowsVoluntaryNumericAndPunctuationTranslation() async {
        for text in ["12345", "?!", "  42  "] {
            var drafts: [ManualTranslationDraft] = []
            let model = makeModel(text: text) { drafts.append($0) }
            await model.submit()
            XCTAssertEqual(drafts.count, 1)
            XCTAssertEqual(drafts.first?.text, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testManualLimitAppliesToTheTrimmedSubmission() async {
        let source = "  " + String(repeating: "a", count: 20_000) + "\n"
        var submitted: ManualTranslationDraft?
        let model = makeModel(text: source) { submitted = $0 }

        await model.submit()

        XCTAssertEqual(submitted?.text.count, 20_000)
        XCTAssertEqual(model.validationCategory, .ready)
    }

    func testManualSubmitRequiresEverySelection() async {
        let model = makeModel(text: "hello") { _ in
            XCTFail("Missing selections must stop before submission")
        }

        model.selectedSourceLanguage = nil
        XCTAssertEqual(model.validationCategory, .missingSelection)
        await model.submit()

        model.selectedSourceLanguage = .automatic
        model.selectedTargetLanguage = nil
        XCTAssertEqual(model.validationCategory, .missingSelection)
        await model.submit()

        model.selectedTargetLanguage = .identified("en")
        model.selectedPresetID = nil
        XCTAssertEqual(model.validationCategory, .missingSelection)
        await model.submit()

        model.selectedPresetID = PresetID(rawValue: "accurate-translation")
        model.selectedProviderID = nil
        XCTAssertEqual(model.validationCategory, .missingSelection)
        await model.submit()
    }

    func testManualSubmissionRoutesThroughCoordinatorAuthorizationWithoutSystemRead() async {
        let authorized = CoordinatorFixture()
        authorized.gate.manualOutcome = .authorized(
            authorized.intent(), authorized.context()
        )
        authorized.engine.updates = [.preparing]
        let authorizedModel = makeModel(text: "manual") { draft in
            await authorized.coordinator.submitManual(draft)
        }
        await authorizedModel.submit()
        await authorized.waitForEngineCalls(1)
        XCTAssertEqual(authorized.systemProcessor.systemReads, 0)
        XCTAssertEqual(authorized.engine.translateCalls.count, 1)

        let rejected = CoordinatorFixture()
        rejected.gate.manualOutcome = .rejected(.providerChanged)
        let rejectedModel = makeModel(text: "manual") { draft in
            await rejected.coordinator.submitManual(draft)
        }
        await rejectedModel.submit()
        XCTAssertEqual(rejected.systemProcessor.systemReads, 0)
        XCTAssertEqual(rejected.engine.translateCalls.count, 0)
        XCTAssertEqual(rejected.feedback.failures, [.destinationReconfirmationRequired])
    }

    func testManualWindowRequestsUseOneKeyedSceneIdentity() {
        let presenter = ManualWindowPresenter()
        presenter.open()
        presenter.open()

        var events: [String] = []
        presenter.openPendingRequests(
            using: { events.append("open:\($0)") },
            activateApplication: { events.append("activate") }
        )
        presenter.openPendingRequests(
            using: { events.append("open:\($0)") },
            activateApplication: { events.append("activate") }
        )

        XCTAssertEqual(presenter.requestCount, 2)
        XCTAssertEqual(presenter.consumedRequestCount, 2)
        XCTAssertEqual(events, ["open:manual-input", "activate"])
        XCTAssertEqual(ManualWindowPresenter.sceneID, "manual-input")
    }

    func testManualWindowCatchesARequestMadeBeforeBridgeConsumption() {
        let presenter = ManualWindowPresenter()
        presenter.open()
        var events: [String] = []

        presenter.openPendingRequests(
            using: { events.append("open:\($0)") },
            activateApplication: { events.append("activate") }
        )

        XCTAssertEqual(events, ["open:manual-input", "activate"])
        XCTAssertEqual(presenter.consumedRequestCount, presenter.requestCount)
    }

    func testPresetPickerPrimaryActionReturnsSelectionWithoutOrdinarySubmit() async {
        let requested = PresetID(rawValue: "polish-expression")
        var submitted: [ManualTranslationDraft] = []
        var selected: [PresetID] = []
        let model = makeModel(text: "") { submitted.append($0) }
        let presenter = ManualWindowPresenter()
        presenter.openPresetPicker(sessionID: UUID(), currentPresetID: requested) {
            selected.append($0)
        }
        model.selectedPresetID = requested
        let view = ManualInputView(viewModel: model, presenter: presenter)

        view.performPrimaryAction()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(selected, [requested])
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertNil(presenter.requestedPresetID)
    }

    func testWindowDisappearanceClearsPresetPickerBeforeOrdinaryReopen() {
        let requested = PresetID(rawValue: "polish-expression")
        var selected: [PresetID] = []
        let model = makeModel(text: "") { _ in }
        let presenter = ManualWindowPresenter()
        presenter.openPresetPicker(sessionID: UUID(), currentPresetID: requested) {
            selected.append($0)
        }
        let view = ManualInputView(viewModel: model, presenter: presenter)

        view.handleWindowDisappearance()
        presenter.selectPreset(requested)

        XCTAssertNil(presenter.requestedPresetID)
        XCTAssertTrue(selected.isEmpty)
    }

    func testCoordinatorUsesFreshConfiguredManualLimitForUIAndSubmission() async {
        let fixture = CoordinatorFixture(systemOutcome: .manualInputRequired)
        fixture.preferences.value.selectionCharacterLimit = 2_000

        await fixture.coordinator.handleMenuTranslateSelectedText()

        XCTAssertEqual(fixture.coordinator.manualInputViewModel.characterLimit, 2_000)
        XCTAssertEqual(fixture.manual.openCount, 1)

        await fixture.coordinator.submitManual(ManualTranslationDraft(
            text: String(repeating: "a", count: 2_001),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID,
            providerID: nil
        ))
        XCTAssertEqual(fixture.gate.manualSubmissions.count, 0)
        XCTAssertEqual(fixture.engine.translateCalls.count, 0)
        XCTAssertEqual(fixture.feedback.failures, [.noValidSelection])
    }

    private func makeModel(
        text: String,
        providerOptions: [ManualProviderOption]? = nil,
        submit: @escaping @MainActor @Sendable (ManualTranslationDraft) async -> Void
    ) -> ManualInputViewModel {
        ManualInputViewModel(
            text: text,
            sourceOptions: [
                ManualLanguageOption(id: "automatic", labelKey: "language.automatic", value: .automatic),
            ],
            targetOptions: [
                ManualLanguageOption(id: "en", labelKey: "language.english", value: .identified("en")),
            ],
            presetOptions: [
                ManualPresetOption(
                    id: PresetID(rawValue: "accurate-translation"),
                    labelKey: "preset.accurate.name"
                ),
            ],
            providerOptions: providerOptions ?? [
                ManualProviderOption(
                    id: "default",
                    configurationID: nil,
                    label: "Default",
                    locality: .localOnDevice
                ),
            ],
            characterLimit: 20_000,
            onCancel: {},
            onSubmit: submit
        )
    }
}
