import XCTest

@testable import ModelProviders

final class TrustVerificationTests: XCTestCase {
    func testPolicyInstallationFailureNeverEvaluatesPriorTrustState() {
        var installationCount = 0
        var evaluationCount = 0

        let accepted = TrustVerification.evaluate(
            installOriginalHostPolicy: {
                installationCount += 1
                return false
            },
            evaluateInstalledPolicy: {
                evaluationCount += 1
                return true
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(installationCount, 1)
        XCTAssertEqual(evaluationCount, 0)
    }

    func testInstalledOriginalHostPolicyIsEvaluatedExactlyOnce() {
        var evaluationCount = 0
        let accepted = TrustVerification.evaluate(
            installOriginalHostPolicy: { true },
            evaluateInstalledPolicy: {
                evaluationCount += 1
                return true
            }
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(evaluationCount, 1)
    }
}
