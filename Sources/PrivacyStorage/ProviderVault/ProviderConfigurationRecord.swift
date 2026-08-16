import Foundation
import SharedSupport

package enum ProviderRecordState: String, Codable, Sendable {
    case pendingCredentialWrite
    case active
    case deletionPending
    case recoveryRequired
}

package enum ProviderConfigurationRole: String, Codable, Sendable {
    case userDefined
    case defaultOllama
}

package enum ProviderRecoveryAction: String, Codable, Sendable {
    case removeRecordAfterCredentialCleanup
    case restoreActiveAfterCredentialCleanup
    case manual
}

package struct ProviderPendingUpdate: Codable, Sendable {
    package var protocolKind: ProviderProtocolKind
    package var endpoint: URL
    package var model: String
    package var pendingCredentialAccount: UUID?
    package var removesCredential: Bool
}

package struct ProviderConfigurationRecord: Codable, Sendable {
    package let id: ProviderConfigurationID
    package var protocolKind: ProviderProtocolKind
    package var endpoint: URL
    package var model: String
    package var confirmedClass: DestinationPrivacyClass?
    package var configurationRevision: UInt64
    package var confirmationRevision: UInt64
    package var activeCredentialAccount: UUID?
    package var pendingCredentialAccount: UUID?
    package var cleanupCredentialAccounts: [UUID]
    package var state: ProviderRecordState
    package var pendingUpdate: ProviderPendingUpdate?
    package var role: ProviderConfigurationRole
    package var recoveryAction: ProviderRecoveryAction?

    private enum CodingKeys: String, CodingKey {
        case id, protocolKind, endpoint, model, confirmedClass
        case configurationRevision, confirmationRevision
        case activeCredentialAccount, pendingCredentialAccount
        case cleanupCredentialAccounts, state, pendingUpdate, role, recoveryAction
    }

    package init(
        id: ProviderConfigurationID,
        protocolKind: ProviderProtocolKind,
        endpoint: URL,
        model: String,
        confirmedClass: DestinationPrivacyClass?,
        configurationRevision: UInt64,
        confirmationRevision: UInt64,
        activeCredentialAccount: UUID?,
        pendingCredentialAccount: UUID?,
        cleanupCredentialAccounts: [UUID],
        state: ProviderRecordState,
        pendingUpdate: ProviderPendingUpdate? = nil,
        role: ProviderConfigurationRole = .userDefined,
        recoveryAction: ProviderRecoveryAction? = nil
    ) {
        self.id = id
        self.protocolKind = protocolKind
        self.endpoint = endpoint
        self.model = model
        self.confirmedClass = confirmedClass
        self.configurationRevision = configurationRevision
        self.confirmationRevision = confirmationRevision
        self.activeCredentialAccount = activeCredentialAccount
        self.pendingCredentialAccount = pendingCredentialAccount
        self.cleanupCredentialAccounts = cleanupCredentialAccounts
        self.state = state
        self.pendingUpdate = pendingUpdate
        self.role = role
        self.recoveryAction = recoveryAction
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderConfigurationID.self, forKey: .id)
        protocolKind = try container.decode(ProviderProtocolKind.self, forKey: .protocolKind)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        model = try container.decode(String.self, forKey: .model)
        confirmedClass = try container.decodeIfPresent(
            DestinationPrivacyClass.self,
            forKey: .confirmedClass
        )
        configurationRevision = try container.decode(UInt64.self, forKey: .configurationRevision)
        confirmationRevision = try container.decode(UInt64.self, forKey: .confirmationRevision)
        activeCredentialAccount = try container.decodeIfPresent(UUID.self, forKey: .activeCredentialAccount)
        pendingCredentialAccount = try container.decodeIfPresent(UUID.self, forKey: .pendingCredentialAccount)
        cleanupCredentialAccounts = try container.decode(
            [UUID].self,
            forKey: .cleanupCredentialAccounts
        )
        state = try container.decode(ProviderRecordState.self, forKey: .state)
        pendingUpdate = try container.decodeIfPresent(ProviderPendingUpdate.self, forKey: .pendingUpdate)
        role = try container.decodeIfPresent(
            ProviderConfigurationRole.self,
            forKey: .role
        ) ?? .userDefined
        recoveryAction = try container.decodeIfPresent(
            ProviderRecoveryAction.self,
            forKey: .recoveryAction
        ) ?? (state == .recoveryRequired ? .manual : nil)
    }
}

package struct ProviderMetadataEnvelope: Codable, Sendable {
    package static let currentVersion: UInt16 = 1
    package static let empty = ProviderMetadataEnvelope(
        version: currentVersion,
        records: [],
        offDeviceAuthorizations: [:]
    )

    package var version: UInt16
    package var records: [ProviderConfigurationRecord]
    package var offDeviceAuthorizations: [ProviderConfigurationID: Set<ApplicationIdentity>]

    package init(
        version: UInt16,
        records: [ProviderConfigurationRecord],
        offDeviceAuthorizations: [ProviderConfigurationID: Set<ApplicationIdentity>]
    ) {
        self.version = version
        self.records = records
        self.offDeviceAuthorizations = offDeviceAuthorizations
    }

    private enum CodingKeys: String, CodingKey {
        case version, records, offDeviceAuthorizations
    }

    private struct AuthorizationEntry: Codable {
        let id: ProviderConfigurationID
        let applications: Set<ApplicationIdentity>
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt16.self, forKey: .version)
        records = try container.decode(
            [ProviderConfigurationRecord].self,
            forKey: .records
        )
        let entries = try container.decode(
            [AuthorizationEntry].self,
            forKey: .offDeviceAuthorizations
        )
        var decoded: [ProviderConfigurationID: Set<ApplicationIdentity>] = [:]
        for entry in entries {
            guard decoded.updateValue(entry.applications, forKey: entry.id) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .offDeviceAuthorizations,
                    in: container,
                    debugDescription: "Duplicate authorization owner"
                )
            }
        }
        offDeviceAuthorizations = decoded
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(records, forKey: .records)
        let entries = offDeviceAuthorizations.map {
            AuthorizationEntry(id: $0.key, applications: $0.value)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        try container.encode(entries, forKey: .offDeviceAuthorizations)
    }


    package func validated() throws -> ProviderMetadataEnvelope {
        guard version == Self.currentVersion,
              records.count <= PrivacyStorageResourceLimits.providerCount,
              offDeviceAuthorizations.count <= records.count else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        var recordIDs = Set<ProviderConfigurationID>()
        var accountOwners: [UUID: ProviderConfigurationID] = [:]
        var defaultCount = 0
        for record in records {
            let pendingUpdateIsBounded = record.pendingUpdate.map {
                $0.endpoint.absoluteString.utf8.count
                    <= PrivacyStorageResourceLimits.providerEndpointUTF8Bytes
                && $0.model.utf8.count
                    <= PrivacyStorageResourceLimits.providerModelUTF8Bytes
            } ?? true
            guard recordIDs.insert(record.id).inserted,
                  record.endpoint.absoluteString.utf8.count
                    <= PrivacyStorageResourceLimits.providerEndpointUTF8Bytes,
                  record.model.utf8.count
                    <= PrivacyStorageResourceLimits.providerModelUTF8Bytes,
                  record.cleanupCredentialAccounts.count
                    <= PrivacyStorageResourceLimits.providerCleanupAccountCount,
                  pendingUpdateIsBounded else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
            let accounts = [
                record.activeCredentialAccount,
                record.pendingCredentialAccount,
                record.pendingUpdate?.pendingCredentialAccount
            ].compactMap { $0 } + record.cleanupCredentialAccounts
            guard Set(accounts).count == accounts.count else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
            for account in accounts {
                guard accountOwners.updateValue(record.id, forKey: account) == nil else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            }
            if record.role == .defaultOllama {
                defaultCount += 1
                guard record.protocolKind == .ollamaNative,
                      record.endpoint.absoluteString == "http://127.0.0.1:11434" else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            }
            if let confirmedClass = record.confirmedClass {
                guard confirmedClass == .localNetwork || confirmedClass == .cloud else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            }
            switch record.state {
            case .active:
                guard record.pendingCredentialAccount == nil,
                      record.recoveryAction == nil else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            case .pendingCredentialWrite:
                guard record.activeCredentialAccount == nil,
                      record.pendingUpdate == nil,
                      record.recoveryAction == nil else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            case .deletionPending:
                guard record.pendingUpdate == nil,
                      record.recoveryAction == nil else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
            case .recoveryRequired:
                guard let action = record.recoveryAction else {
                    throw SanitizedFailure.invalidProviderConfiguration
                }
                switch action {
                case .removeRecordAfterCredentialCleanup:
                    guard record.pendingUpdate == nil else {
                        throw SanitizedFailure.invalidProviderConfiguration
                    }
                case .restoreActiveAfterCredentialCleanup:
                    guard record.pendingUpdate != nil else {
                        throw SanitizedFailure.invalidProviderConfiguration
                    }
                case .manual:
                    break
                }
            }
        }
        guard defaultCount <= 1 else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        guard Set(offDeviceAuthorizations.keys).isSubset(of: recordIDs) else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        for applications in offDeviceAuthorizations.values {
            guard PrivacyStorageResourceLimits.validateApplications(
                applications
            ) else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
        }
        return self
    }
}
