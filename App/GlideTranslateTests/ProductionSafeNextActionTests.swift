import XCTest
import SharedSupport

@testable import GlideTranslate

@MainActor
final class ProductionSafeNextActionTests: XCTestCase {
    func testEveryTypedActionRoutesOnlyToItsExplicitProductionDestination() {
        let spy = RouteSpy()
        let router = spy.makeRouter()

        for action in SafeNextAction.allTestCases {
            let before = spy.destinations
            router.route(action)
            if let destination = action.explicitDestination {
                XCTAssertEqual(spy.destinations, before + [destination], String(describing: action))
            } else {
                XCTAssertEqual(spy.destinations, before, String(describing: action))
            }
        }
    }

    func testPresenterDoesNotRouteUntilActionButtonIsConfirmed() {
        let spy = RouteSpy()
        let confirmation = ConfirmationState()
        let presenter = ProductionCoordinatorFeedbackPresenter(
            router: spy.makeRouter(),
            alertRunner: { _, actionTitle, _ in
                XCTAssertNotNil(actionTitle)
                return confirmation.isConfirmed
            }
        )
        let presentation = SanitizedFailure.invalidProviderConfiguration
            .safeNextActionPresentation

        presenter.presentSafeNextAction(presentation)
        XCTAssertTrue(spy.destinations.isEmpty)

        confirmation.isConfirmed = true
        presenter.presentSafeNextAction(presentation)
        XCTAssertEqual(spy.destinations, [.settings])
    }

    func testNoneUsesAcknowledgementOnlyAndNeverRoutes() {
        let spy = RouteSpy()
        var observedActionTitle: String?
        let presenter = ProductionCoordinatorFeedbackPresenter(
            router: spy.makeRouter(),
            alertRunner: { _, actionTitle, _ in
                observedActionTitle = actionTitle
                return true
            }
        )
        presenter.presentSafeNextAction(
            SafeNextActionPresentation(
                action: .none,
                messageKey: "error.translation.cancelled.message",
                nextActionKey: "error.translation.cancelled.nextAction",
                sanitizedFailure: .cancelled
            )
        )

        XCTAssertNil(observedActionTitle)
        XCTAssertTrue(spy.destinations.isEmpty)
    }
}

@MainActor
private final class RouteSpy {
    private(set) var destinations: [SafeNextActionDestination] = []

    func makeRouter() -> ProductionSafeNextActionRouter {
        ProductionSafeNextActionRouter(
            openSettings: { self.destinations.append(.settings) },
            openManualInput: { self.destinations.append(.manualInput) },
            openAccessibilitySettings: {
                self.destinations.append(.accessibilitySettings)
            }
        )
    }
}

@MainActor
private final class ConfirmationState {
    var isConfirmed = false
}

private extension SafeNextAction {
    static let allTestCases: [SafeNextAction] = [
        .openAccessibilitySettingsOrUseManualInput,
        .resumeAutomaticOrUseShortcut,
        .enableApplicationOrUseShortcut,
        .authorizeApplicationOrUseExplicitAction,
        .openManualInput,
        .useManualInput,
        .showLocalRuntimeGuidance,
        .chooseOrInstallModelManually,
        .openModelSettings,
        .replaceCredential,
        .reconfirmDestination,
        .retryOrAdjustTimeout,
        .retryOrReviewProvider,
        .none,
        .explainHistoryDisabled,
        .explainApplicationExcluded,
        .deleteAndRestartHistory,
    ]
}
