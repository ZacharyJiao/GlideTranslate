import SharedSupport

public protocol PreferencesStore: Sendable {
    func snapshot() async throws -> PreferencesSnapshot
    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws
}

package protocol OffDeviceAuthorizationReconciling: Sendable {
    func reconcileOffDeviceAuthorizations(
        withGeneralAllowlistCeiling ceiling: Set<ApplicationIdentity>
    ) async throws
}
