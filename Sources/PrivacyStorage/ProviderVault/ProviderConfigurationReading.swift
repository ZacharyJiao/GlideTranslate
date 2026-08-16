import Foundation
import SharedSupport

package struct ProviderConfigurationReadDescriptor: Sendable {
    package let id: ProviderConfigurationID
    package let protocolKind: ProviderProtocolKind
    package let endpoint: URL
    package let model: String
    package let hasCredential: Bool
    package let confirmedClass: DestinationPrivacyClass?
    package let configurationRevision: UInt64
    package let confirmationRevision: UInt64

    package init(
        id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind,
        endpoint: URL,
        model: String,
        hasCredential: Bool,
        confirmedClass: DestinationPrivacyClass?,
        configurationRevision: UInt64,
        confirmationRevision: UInt64
    ) {
        self.id = id
        self.protocolKind = protocolKind
        self.endpoint = endpoint
        self.model = model
        self.hasCredential = hasCredential
        self.confirmedClass = confirmedClass
        self.configurationRevision = configurationRevision
        self.confirmationRevision = confirmationRevision
    }
}

package protocol ProviderConfigurationReading: Sendable {
    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor
}
