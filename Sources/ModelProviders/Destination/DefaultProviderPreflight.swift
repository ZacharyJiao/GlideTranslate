import PrivacyStorage
import SharedSupport

package protocol DestinationSnapshotMintObserving: Sendable {
    func didMintDestinationSnapshot()
}

private struct NoOpDestinationSnapshotMintObserver:
    DestinationSnapshotMintObserving {
    func didMintDestinationSnapshot() {}
}

package struct ResolvedProviderEvidence: Sendable {
    package let descriptor: ProviderConfigurationReadDescriptor
    package let endpoint: ParsedProviderEndpoint
    package let addresses: Set<IPAddress>
    package let privacyClass: DestinationPrivacyClass

    package var fingerprint: Set<String> {
        Set(addresses.map(\.fingerprint))
    }
}

package enum ProviderDestinationResolver {
    package static func resolve(
        descriptor: ProviderConfigurationReadDescriptor,
        using resolver: any AddressResolving
    ) async throws -> ResolvedProviderEvidence {
        let endpoint = try ProviderOriginParser.parse(descriptor.endpoint)
        let addresses = try await resolver.resolve(endpoint.origin.host)
        return ResolvedProviderEvidence(
            descriptor: descriptor,
            endpoint: endpoint,
            addresses: addresses,
            privacyClass: DestinationClassifier.classify(
                addresses,
                for: endpoint
            )
        )
    }
}

enum RedirectDestinationEvidenceFailure: Error {
    case unresolved
    case changed
}

enum RedirectDestinationSnapshotMinter {
    static func mint(
        previous: ProviderDestinationSnapshot,
        endpoint: ParsedProviderEndpoint,
        addresses: Set<IPAddress>
    ) throws -> (ProviderDestinationSnapshot, IPAddress) {
        guard !addresses.isEmpty else {
            throw RedirectDestinationEvidenceFailure.unresolved
        }
        let privacyClass = DestinationClassifier.classify(
            addresses,
            for: endpoint
        )
        guard privacyClass != .unresolvedOrChanged else {
            throw RedirectDestinationEvidenceFailure.unresolved
        }
        guard endpoint.origin == previous.origin,
              privacyClass == previous.privacyClass else {
            throw RedirectDestinationEvidenceFailure.changed
        }
        let confirmedClass: DestinationPrivacyClass? = privacyClass == .localOnDevice
            ? nil
            : privacyClass
        guard case .success = EndpointPolicy.validate(
            endpoint: endpoint,
            resolvedClass: privacyClass,
            confirmedClass: confirmedClass
        ) else {
            throw RedirectDestinationEvidenceFailure.changed
        }
        guard let numericAddress = addresses.sorted(by: {
            $0.fingerprint < $1.fingerprint
        }).first else {
            throw RedirectDestinationEvidenceFailure.unresolved
        }
        let snapshot = ProviderDestinationSnapshot.mintAfterResolution(
            configurationID: previous.configurationID,
            privacyClass: privacyClass,
            configurationRevision: previous.configurationRevision,
            confirmationRevision: previous.confirmationRevision,
            origin: endpoint.origin,
            resolutionFingerprint: Set(addresses.map(\.fingerprint)),
            protocolKind: previous.protocolKind,
            model: previous.model
        )
        return (snapshot, numericAddress)
    }
}

package struct DefaultProviderPreflight: ProviderPreflight {
    private let repository: any ProviderConfigurationReading
    private let resolver: any AddressResolving
    private let mintObserver: any DestinationSnapshotMintObserving

    package init(
        repository: any ProviderConfigurationReading,
        resolver: any AddressResolving
    ) {
        self.init(
            repository: repository,
            resolver: resolver,
            mintObserver: NoOpDestinationSnapshotMintObserver()
        )
    }

    package init(
        repository: any ProviderConfigurationReading,
        resolver: any AddressResolving,
        mintObserver: any DestinationSnapshotMintObserving
    ) {
        self.repository = repository
        self.resolver = resolver
        self.mintObserver = mintObserver
    }

    package func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        do {
            let descriptor = try await repository.accessDescriptor(configurationID)
            guard descriptor.id == configurationID else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
            let evidence = try await ProviderDestinationResolver.resolve(
                descriptor: descriptor,
                using: resolver
            )
            do {
                try EndpointPolicy.validate(
                    endpoint: evidence.endpoint,
                    resolvedClass: evidence.privacyClass,
                    confirmedClass: descriptor.confirmedClass
                ).get()
            } catch EndpointFailure.httpsRequired {
                throw SanitizedFailure.invalidProviderConfiguration
            } catch {
                throw SanitizedFailure.destinationReconfirmationRequired
            }
            guard descriptor.confirmedClass == nil
                    && evidence.privacyClass == .localOnDevice
                    || descriptor.confirmedClass == evidence.privacyClass else {
                throw SanitizedFailure.destinationReconfirmationRequired
            }
            mintObserver.didMintDestinationSnapshot()
            return .success(.mintAfterResolution(
                configurationID: descriptor.id,
                privacyClass: evidence.privacyClass,
                configurationRevision: descriptor.configurationRevision,
                confirmationRevision: descriptor.confirmationRevision,
                origin: evidence.endpoint.origin,
                resolutionFingerprint: evidence.fingerprint,
                protocolKind: descriptor.protocolKind,
                model: descriptor.model
            ))
        } catch let failure as SanitizedFailure {
            return .failure(failure)
        } catch let failure as EndpointFailure {
            switch failure {
            case .httpsRequired:
                return .failure(.invalidProviderConfiguration)
            case .confirmationRequired, .destinationUnresolved:
                return .failure(.destinationReconfirmationRequired)
            case .invalidURL, .missingHost, .embeddedCredentials,
                    .unsupportedScheme:
                return .failure(.invalidProviderConfiguration)
            }
        } catch is AddressFailure {
            return .failure(.destinationReconfirmationRequired)
        } catch {
            return .failure(.invalidProviderConfiguration)
        }
    }

    package func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }
}
