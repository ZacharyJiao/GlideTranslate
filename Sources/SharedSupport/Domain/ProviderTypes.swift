import Foundation

public struct ProviderConfigurationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ProviderProtocolKind: String, Codable, Sendable {
    case ollamaNative
    case openAICompatible
}

public struct ProviderOrigin: Equatable, Hashable, Sendable {
    package let scheme: String
    package let host: String
    package let effectivePort: UInt16

    package init(scheme: String, host: String, effectivePort: UInt16) {
        self.scheme = scheme
        self.host = host
        self.effectivePort = effectivePort
    }
}

public struct ProviderDestinationSnapshot: Equatable, Sendable {
    public let configurationID: ProviderConfigurationID
    public let privacyClass: DestinationPrivacyClass
    public let configurationRevision: UInt64
    public let confirmationRevision: UInt64
    package let origin: ProviderOrigin
    package let resolutionFingerprint: Set<String>
    package let protocolKind: ProviderProtocolKind
    package let model: String

    private init(
        configurationID: ProviderConfigurationID,
        privacyClass: DestinationPrivacyClass,
        configurationRevision: UInt64,
        confirmationRevision: UInt64,
        origin: ProviderOrigin,
        resolutionFingerprint: Set<String>,
        protocolKind: ProviderProtocolKind,
        model: String
    ) {
        self.configurationID = configurationID
        self.privacyClass = privacyClass
        self.configurationRevision = configurationRevision
        self.confirmationRevision = confirmationRevision
        self.origin = origin
        self.resolutionFingerprint = resolutionFingerprint
        self.protocolKind = protocolKind
        self.model = model
    }

    package static func mintAfterResolution(
        configurationID: ProviderConfigurationID,
        privacyClass: DestinationPrivacyClass,
        configurationRevision: UInt64,
        confirmationRevision: UInt64,
        origin: ProviderOrigin,
        resolutionFingerprint: Set<String>,
        protocolKind: ProviderProtocolKind,
        model: String
    ) -> Self {
        Self(
            configurationID: configurationID,
            privacyClass: privacyClass,
            configurationRevision: configurationRevision,
            confirmationRevision: confirmationRevision,
            origin: origin,
            resolutionFingerprint: resolutionFingerprint,
            protocolKind: protocolKind,
            model: model
        )
    }

}

public struct ProviderConfirmationChallenge: Sendable {
    public let configurationID: ProviderConfigurationID
    public let proposedClass: DestinationPrivacyClass
    package let configurationRevision: UInt64
    package let confirmationRevision: UInt64
    package let origin: ProviderOrigin
    package let resolutionFingerprint: Set<String>

    package init(
        configurationID: ProviderConfigurationID,
        proposedClass: DestinationPrivacyClass,
        configurationRevision: UInt64,
        confirmationRevision: UInt64,
        origin: ProviderOrigin,
        resolutionFingerprint: Set<String>
    ) {
        self.configurationID = configurationID
        self.proposedClass = proposedClass
        self.configurationRevision = configurationRevision
        self.confirmationRevision = confirmationRevision
        self.origin = origin
        self.resolutionFingerprint = resolutionFingerprint
    }
}
