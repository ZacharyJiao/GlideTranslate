import XCTest
@testable import SharedSupport

final class StableValueTests: XCTestCase {
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
