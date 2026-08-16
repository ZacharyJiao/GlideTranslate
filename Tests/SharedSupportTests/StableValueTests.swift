import XCTest
@testable import SharedSupport

final class StableValueTests: XCTestCase {
    func testApplicationIdentityMatchesLocalizedRuntimeNameByBundleIdentifier() {
        let configured = ApplicationIdentity(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "TextEdit"
        )
        let running = ApplicationIdentity(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "文本编辑"
        )

        XCTAssertEqual(configured, running)
        XCTAssertTrue(Set([configured]).contains(running))
    }

    func testProviderSnapshotChangesWhenConfigurationRevisionChanges() {
        let id = ProviderConfigurationID()
        let origin = ProviderOrigin(
            scheme: "https",
            host: "example.invalid",
            effectivePort: 443
        )
        let first = ProviderDestinationSnapshot.mintAfterResolution(
            configurationID: id,
            privacyClass: .cloud,
            configurationRevision: 1,
            confirmationRevision: 1,
            origin: origin,
            resolutionFingerprint: ["203.0.113.1"],
            protocolKind: .openAICompatible,
            model: ["synthetic", "model"].joined(separator: "-")
        )
        let changed = ProviderDestinationSnapshot.mintAfterResolution(
            configurationID: id,
            privacyClass: .cloud,
            configurationRevision: 2,
            confirmationRevision: 1,
            origin: origin,
            resolutionFingerprint: ["203.0.113.1"],
            protocolKind: .openAICompatible,
            model: ["synthetic", "model"].joined(separator: "-")
        )
        XCTAssertNotEqual(first, changed)
    }
}
