import SharedSupport

package enum EndpointPolicy {
    package static func validate(
        endpoint: ParsedProviderEndpoint,
        resolvedClass: DestinationPrivacyClass,
        confirmedClass: DestinationPrivacyClass?
    ) -> Result<Void, EndpointFailure> {
        switch resolvedClass {
        case .unresolvedOrChanged:
            return .failure(.destinationUnresolved)
        case .cloud:
            guard endpoint.origin.scheme == "https" else {
                return .failure(.httpsRequired)
            }
            return confirmedClass == .cloud
                ? .success(())
                : .failure(.confirmationRequired)
        case .localNetwork:
            return confirmedClass == .localNetwork
                ? .success(())
                : .failure(.confirmationRequired)
        case .localOnDevice:
            return .success(())
        }
    }
}
