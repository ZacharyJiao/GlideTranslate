import PrivacyStorage
import SharedSupport

package struct DefaultProviderConfirmationService: ProviderConfirmationService {
    private let repository: any ProviderConfigurationReading
    private let resolver: any AddressResolving
    private let committer: any ProviderConfirmationCommitting
    private let mintObserver: any DestinationSnapshotMintObserving

    package init(
        repository: any ProviderConfigurationReading,
        resolver: any AddressResolving,
        committer: any ProviderConfirmationCommitting
    ) {
        self.init(
            repository: repository,
            resolver: resolver,
            committer: committer,
            mintObserver: NoOpConfirmationMintObserver()
        )
    }

    package init(
        repository: any ProviderConfigurationReading,
        resolver: any AddressResolving,
        committer: any ProviderConfirmationCommitting,
        mintObserver: any DestinationSnapshotMintObserving
    ) {
        self.repository = repository
        self.resolver = resolver
        self.committer = committer
        self.mintObserver = mintObserver
    }

    package func prepareConfirmation(
        for id: ProviderConfigurationID
    ) async throws -> ProviderConfirmationChallenge {
        let descriptor: ProviderConfigurationReadDescriptor
        do {
            descriptor = try await repository.accessDescriptor(id)
        } catch let failure as SanitizedFailure {
            throw failure
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        guard descriptor.id == id else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let evidence: ResolvedProviderEvidence
        do {
            evidence = try await ProviderDestinationResolver.resolve(
                descriptor: descriptor,
                using: resolver
            )
        } catch is AddressFailure {
            throw SanitizedFailure.destinationReconfirmationRequired
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }

        switch evidence.privacyClass {
        case .cloud:
            guard evidence.endpoint.origin.scheme == "https" else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
        case .localNetwork:
            break
        case .localOnDevice:
            throw SanitizedFailure.invalidProviderConfiguration
        case .unresolvedOrChanged:
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        return ProviderConfirmationChallenge(
            configurationID: descriptor.id,
            proposedClass: evidence.privacyClass,
            configurationRevision: descriptor.configurationRevision,
            confirmationRevision: descriptor.confirmationRevision,
            origin: evidence.endpoint.origin,
            resolutionFingerprint: evidence.fingerprint
        )
    }

    package func confirm(
        _ challenge: ProviderConfirmationChallenge
    ) async throws -> ProviderDestinationSnapshot {
        let descriptor: ProviderConfigurationReadDescriptor
        let evidence: ResolvedProviderEvidence
        do {
            descriptor = try await repository.accessDescriptor(
                challenge.configurationID
            )
            evidence = try await ProviderDestinationResolver.resolve(
                descriptor: descriptor,
                using: resolver
            )
        } catch {
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        guard descriptor.id == challenge.configurationID,
              descriptor.configurationRevision == challenge.configurationRevision,
              descriptor.confirmationRevision == challenge.confirmationRevision,
              evidence.endpoint.origin == challenge.origin,
              evidence.fingerprint == challenge.resolutionFingerprint,
              evidence.privacyClass == challenge.proposedClass,
              challenge.proposedClass == .localNetwork
                || challenge.proposedClass == .cloud else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        if challenge.proposedClass == .cloud {
            guard evidence.endpoint.origin.scheme == "https" else {
                throw SanitizedFailure.destinationReconfirmationRequired
            }
        }
        guard challenge.confirmationRevision < UInt64.max else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        let committed: ProviderConfirmationCommit
        do {
            committed = try await committer.commitConfirmation(
                id: descriptor.id,
                expectedConfigurationRevision: challenge.configurationRevision,
                expectedConfirmationRevision: challenge.confirmationRevision,
                proposedClass: challenge.proposedClass
            )
        } catch let failure as SanitizedFailure {
            throw failure
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        guard committed.configurationRevision == challenge.configurationRevision,
              committed.confirmationRevision == challenge.confirmationRevision + 1 else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        mintObserver.didMintDestinationSnapshot()
        return .mintAfterResolution(
            configurationID: descriptor.id,
            privacyClass: evidence.privacyClass,
            configurationRevision: committed.configurationRevision,
            confirmationRevision: committed.confirmationRevision,
            origin: evidence.endpoint.origin,
            resolutionFingerprint: evidence.fingerprint,
            protocolKind: descriptor.protocolKind,
            model: descriptor.model
        )
    }
}

private struct NoOpConfirmationMintObserver:
    DestinationSnapshotMintObserving {
    func didMintDestinationSnapshot() {}
}
