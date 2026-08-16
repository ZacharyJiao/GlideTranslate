import SharedSupport

package enum SendAuthorizationPolicy {
    package static func evaluate(
        expected: ProviderDestinationSnapshot,
        current: ProviderDestinationSnapshot
    ) -> Result<Void, SelectionAuthorizationFailure> {
        guard current.privacyClass != .unresolvedOrChanged else {
            return .failure(.providerDestinationUnresolved)
        }
        guard expected == current else {
            return .failure(.providerChanged)
        }
        return .success(())
    }
}
