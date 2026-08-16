import Foundation
import SharedSupport

public struct SanitizedProviderDescriptor: Identifiable, Sendable {
    public let id: ProviderConfigurationID
    public let protocolKind: ProviderProtocolKind
    public let privacyClass: DestinationPrivacyClass
    public let hasCredential: Bool

    package init(
        id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind,
        privacyClass: DestinationPrivacyClass,
        hasCredential: Bool
    ) {
        self.id = id
        self.protocolKind = protocolKind
        self.privacyClass = privacyClass
        self.hasCredential = hasCredential
    }
}

public struct ProviderConfigurationDraft: Sendable {
    public let protocolKind: ProviderProtocolKind
    public let endpoint: URL
    public let model: String

    public init(protocolKind: ProviderProtocolKind, endpoint: URL, model: String) {
        self.protocolKind = protocolKind
        self.endpoint = endpoint
        self.model = model
    }
}

public struct ProviderConfigurationDetails: Sendable {
    public let id: ProviderConfigurationID
    public let protocolKind: ProviderProtocolKind
    public let endpoint: URL
    public let model: String
    public let privacyClass: DestinationPrivacyClass
    public let hasCredential: Bool

    package init(
        id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind,
        endpoint: URL,
        model: String,
        privacyClass: DestinationPrivacyClass,
        hasCredential: Bool
    ) {
        self.id = id
        self.protocolKind = protocolKind
        self.endpoint = endpoint
        self.model = model
        self.privacyClass = privacyClass
        self.hasCredential = hasCredential
    }
}

public struct SensitiveCredentialInput: ~Copyable, Sendable {
    let value: String

    public init(_ value: consuming String) {
        self.value = value
    }
}

public enum ProviderCredentialChange: ~Copyable, Sendable {
    case preserve
    case remove
    case replace(SensitiveCredentialInput)
}

public protocol ProviderManagement: Sendable {
    func descriptors() async throws -> [SanitizedProviderDescriptor]
    func configuration(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationDetails
    func create(
        _ draft: ProviderConfigurationDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SanitizedProviderDescriptor
    func update(
        _ id: ProviderConfigurationID,
        draft: ProviderConfigurationDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SanitizedProviderDescriptor
    func ensureDefaultOllamaConfiguration() async throws
        -> SanitizedProviderDescriptor
    func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity>
    func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws
    func delete(_ id: ProviderConfigurationID) async throws
}
