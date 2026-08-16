import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class IntegratedPrivacyInvariantTests: XCTestCase {
    func testRealHistoryOutcomesUseProductionSafeActionAuthority() {
        XCTAssertNil(HistoryWriteOutcome.stored.safeNextActionPresentation)
        XCTAssertEqual(
            HistoryWriteOutcome.skipped(.disabled)
                .safeNextActionPresentation?.action,
            .explainHistoryDisabled
        )
        XCTAssertEqual(
            HistoryWriteOutcome.skipped(.excludedApplication)
                .safeNextActionPresentation?.action,
            .explainApplicationExcluded
        )
    }

    func testEveryFailureCaseConstructsCompilingHarness() {
        let cases = IntegratedFailureCase.allCases
        let harnesses = cases.map(IntegratedHarness.init(failure:))

        XCTAssertEqual(cases.count, 20)
        XCTAssertEqual(harnesses.map(\.failure), cases)
    }

    func testAllFailuresDegradeWithoutSensitiveEffects() async {
        for failureCase in IntegratedFailureCase.allCases {
            let harness = IntegratedHarness(failure: failureCase)
            await harness.performTrigger()

            XCTAssertEqual(
                harness.presentedNextAction,
                failureCase.expectedNextAction,
                String(describing: failureCase)
            )
            XCTAssertEqual(
                harness.alternateProviderCalls,
                0,
                String(describing: failureCase)
            )
            XCTAssertTrue(harness.outcomeObserved, String(describing: failureCase))
            XCTAssertEqual(
                harness.providerCalls,
                failureCase.expectedProviderCalls,
                String(describing: failureCase)
            )
            XCTAssertEqual(
                harness.credentialReads,
                failureCase.expectedCredentialReads,
                String(describing: failureCase)
            )
            XCTAssertTrue(
                harness.logs.areRuntimeMarkerFree,
                String(describing: failureCase)
            )
            XCTAssertTrue(
                harness.diagnosticPreview.wasBuilt,
                String(describing: failureCase)
            )
            XCTAssertTrue(
                harness.diagnosticPreview.isRuntimeMarkerFree,
                String(describing: failureCase)
            )
            if failureCase.rejectsBeforeSystemRead {
                XCTAssertEqual(harness.axReads, 0, String(describing: failureCase))
                XCTAssertEqual(
                    harness.pasteboardReads,
                    0,
                    String(describing: failureCase)
                )
                XCTAssertEqual(
                    harness.providerCalls,
                    0,
                    String(describing: failureCase)
                )
            }
            if failureCase.rejectsBeforeSend {
                XCTAssertEqual(
                    harness.providerCalls,
                    0,
                    String(describing: failureCase)
                )
                XCTAssertEqual(
                    harness.credentialReads,
                    0,
                    String(describing: failureCase)
                )
            }
            XCTAssertEqual(
                harness.historyWrites,
                failureCase.expectedHistoryWrites,
                String(describing: failureCase)
            )
            if failureCase == .userCancellation {
                XCTAssertEqual(harness.feedbackPresentationCount, 0)
            }
            if [.historyDisabled, .applicationExcluded, .historyUnrecoverable]
                .contains(failureCase) {
                XCTAssertEqual(
                    harness.feedbackPresentationCount,
                    1,
                    String(describing: failureCase)
                )
            }
        }
    }

    func testEveryTypedFailurePresentationUsesCatalogedLocalization() throws {
        let selectionFailures: [SelectionAuthorizationFailure] = [
            .cancelled,
            .automaticCapturePaused,
            .mouseCaptureDisabled,
            .keyboardCaptureDisabled,
            .applicationNotAllowed,
            .offDeviceApplicationNotAllowed,
            .providerDestinationUnresolved,
            .providerChanged,
            .accessibilityPermissionMissing,
            .unsupportedApplication,
            .selectionReadTimedOut,
            .noValidSelection,
            .unsafeFallbackState,
            .snapshotTooLarge,
            .foregroundApplicationChanged,
        ]
        let presentations = selectionFailures.map(IntegratedSafeFailureMapping.presentation)
            + SanitizedFailure.allCases.map(IntegratedSafeFailureMapping.presentation)
            + [HistorySkipReason.disabled, .excludedApplication].map { reason in
                let presentation = reason.safeNextActionPresentation
                return IntegratedSafePresentation(
                    nextAction: presentation.action,
                    localizationKey: presentation.nextActionKey
                )
            }
        let localizedBundles = try ["en", "zh-Hans"].map { locale in
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: locale, ofType: "lproj"),
                locale
            )
            return try XCTUnwrap(Bundle(path: path), locale)
        }

        for presentation in presentations {
            for bundle in localizedBundles {
                XCTAssertNotEqual(
                    bundle.localizedString(
                        forKey: presentation.localizationKey,
                        value: nil,
                        table: nil
                    ),
                    presentation.localizationKey,
                    presentation.localizationKey
                )
            }
        }
    }
}
