import SharedSupport
import XCTest
@testable import SelectionCapture

final class ProviderSnapshotInvalidationTests: XCTestCase {
    func testEveryProviderMutationRejectsBeforeMint() async {
        for mutation in SnapshotMutation.allCases {
            let fixture = AuthorizationFixture()
            fixture.snapshotReader.result = .success(fixture.expected.changing(mutation))
            let result = await fixture.gate.authorizeSystemSelection(
                trigger: .mouse,
                context: fixture.context,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
            XCTAssertEqual(result.failure, .providerChanged, String(describing: mutation))
            XCTAssertEqual(fixture.systemReader.count.value, 1)
            XCTAssertEqual(fixture.clipboardReader.count.value, 0)
            XCTAssertEqual(fixture.mintSpy.count.value, 0)
        }
    }

    func testUnchangedSnapshotMintsExactlyOnce() async {
        let fixture = AuthorizationFixture()
        let result = await fixture.gate.authorizeSystemSelection(
            trigger: .mouse,
            context: fixture.context,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertTrue(result.isAuthorized)
        XCTAssertEqual(fixture.systemReader.count.value, 1)
        XCTAssertEqual(fixture.snapshotReader.count.value, 1)
        XCTAssertEqual(fixture.mintSpy.count.value, 1)
    }
}
