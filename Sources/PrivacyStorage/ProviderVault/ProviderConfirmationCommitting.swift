import SharedSupport

package struct ProviderConfirmationCommit: Equatable, Sendable {
    package let configurationRevision: UInt64
    package let confirmationRevision: UInt64

    package init(
        configurationRevision: UInt64,
        confirmationRevision: UInt64
    ) {
        self.configurationRevision = configurationRevision
        self.confirmationRevision = confirmationRevision
    }
}

package protocol ProviderConfirmationCommitting: Sendable {
    func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) async throws -> ProviderConfirmationCommit
}
