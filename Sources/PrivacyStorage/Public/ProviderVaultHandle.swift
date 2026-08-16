public struct ProviderVaultHandle: Sendable {
    package let access: any ProviderAccess
    package let confirmation: any ProviderConfirmationCommitting

    package init(
        access: any ProviderAccess,
        confirmation: any ProviderConfirmationCommitting
    ) {
        self.access = access
        self.confirmation = confirmation
    }
}
