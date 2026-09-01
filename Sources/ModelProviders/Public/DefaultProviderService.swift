import PrivacyStorage
import SharedSupport

package protocol OllamaProviderAdapting: Sendable {
    func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error>
    func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String]
    func testConnection(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws
}

package protocol OpenAICompatibleProviderAdapting: Sendable {
    func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error>
    func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String]
    func testConnection(at initial: RedirectAcceptedHop) async throws
}

extension OllamaProvider: OllamaProviderAdapting {}
extension OpenAICompatibleProvider: OpenAICompatibleProviderAdapting {}

public final class DefaultProviderService:
    ProviderService,
    ProviderInspection,
    Sendable {
    private let preflight: any ProviderPreflight
    private let access: any ProviderAccess
    private let ollama: any OllamaProviderAdapting
    private let compatible: any OpenAICompatibleProviderAdapting

    package init(
        preflight: any ProviderPreflight,
        access: any ProviderAccess,
        ollama: any OllamaProviderAdapting,
        compatible: any OpenAICompatibleProviderAdapting
    ) {
        self.preflight = preflight
        self.access = access
        self.ollama = ollama
        self.compatible = compatible
    }

    public func generate(
        _ request: TranslationRequest,
        authorizedDestination: ProviderDestinationSnapshot
    ) async -> AsyncThrowingStream<TranslationChunk, Error> {
        do {
            let prepared = try await prepare(
                id: authorizedDestination.configurationID,
                requiring: authorizedDestination
            )
            guard request.model == prepared.snapshot.model else {
                throw SanitizedFailure.destinationReconfirmationRequired
            }
            guard !prepared.snapshot.model.isEmpty else {
                throw SanitizedFailure.modelUnavailable
            }
            switch prepared.snapshot.protocolKind {
            case .ollamaNative:
                return try await ollama.generate(
                    request,
                    at: prepared.hop,
                    requiresCredential: prepared.requiresCredential
                )
            case .openAICompatible:
                return try await compatible.generate(
                    request,
                    at: prepared.hop,
                    requiresCredential: prepared.requiresCredential
                )
            }
        } catch {
            return Self.failedStream(Self.sanitizePreparation(error))
        }
    }

    public func discoverModels(
        for configurationID: ProviderConfigurationID
    ) async throws -> [String] {
        let prepared = try await prepare(id: configurationID, requiring: nil)
        switch prepared.snapshot.protocolKind {
        case .ollamaNative:
            return try await ollama.discoverModels(
                at: prepared.hop,
                requiresCredential: prepared.requiresCredential
            )
        case .openAICompatible:
            return try await compatible.discoverModels(
                at: prepared.hop,
                requiresCredential: prepared.requiresCredential
            )
        }
    }

    public func testConnection(
        for configurationID: ProviderConfigurationID
    ) async throws {
        let prepared = try await prepare(id: configurationID, requiring: nil)
        switch prepared.snapshot.protocolKind {
        case .ollamaNative:
            try await ollama.testConnection(
                at: prepared.hop,
                requiresCredential: prepared.requiresCredential
            )
        case .openAICompatible:
            try await compatible.testConnection(at: prepared.hop)
        }
    }

    private func prepare(
        id: ProviderConfigurationID,
        requiring authorized: ProviderDestinationSnapshot?
    ) async throws -> (
        snapshot: ProviderDestinationSnapshot,
        hop: RedirectAcceptedHop,
        requiresCredential: Bool
    ) {
        let fresh = try await preflight.resolveDestination(for: id).get()
        if let authorized, fresh != authorized {
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        let descriptor: ProviderConfigurationReadDescriptor
        do {
            descriptor = try await access.accessDescriptor(id)
        } catch let failure as SanitizedFailure {
            throw failure
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let endpoint: ParsedProviderEndpoint
        do {
            endpoint = try ProviderOriginParser.parse(descriptor.endpoint)
        } catch {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        guard descriptor.id == fresh.configurationID,
              descriptor.id == id,
              descriptor.configurationRevision == fresh.configurationRevision,
              descriptor.confirmationRevision == fresh.confirmationRevision,
              descriptor.protocolKind == fresh.protocolKind,
              descriptor.model == fresh.model,
              endpoint.origin == fresh.origin,
              Self.matchesConfirmation(
                descriptor.confirmedClass,
                privacyClass: fresh.privacyClass
              ) else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }

        let addresses: [IPAddress]
        do {
            addresses = try fresh.resolutionFingerprint.map {
                try IPAddress(fingerprint: $0)
            }
        } catch {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        guard !addresses.isEmpty,
              Set(addresses.map(\.fingerprint)) == fresh.resolutionFingerprint,
              DestinationClassifier.classify(
                  Set(addresses),
                  for: endpoint
              ) == fresh.privacyClass,
              let numericAddress = addresses.sorted(by: {
                  $0.canonicalSortKey.lexicographicallyPrecedes($1.canonicalSortKey)
              }).first else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        do {
            try EndpointPolicy.validate(
                endpoint: endpoint,
                resolvedClass: fresh.privacyClass,
                confirmedClass: descriptor.confirmedClass
            ).get()
        } catch {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        return (
            fresh,
            RedirectAcceptedHop(
                endpoint: endpoint,
                snapshot: fresh,
                numericAddress: numericAddress
            ),
            descriptor.hasCredential
        )
    }

    private static func matchesConfirmation(
        _ confirmed: DestinationPrivacyClass?,
        privacyClass: DestinationPrivacyClass
    ) -> Bool {
        if confirmed == nil { return privacyClass == .localOnDevice }
        return confirmed == privacyClass
    }

    private static func sanitizePreparation(_ error: Error) -> SanitizedFailure {
        if let failure = error as? SanitizedFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .invalidProviderConfiguration
    }

    private static func failedStream(
        _ failure: SanitizedFailure
    ) -> AsyncThrowingStream<TranslationChunk, Error> {
        let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()
        pair.continuation.finish(throwing: failure)
        return pair.stream
    }
}
