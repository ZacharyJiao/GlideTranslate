import SharedSupport

package enum ProviderAuthorizationFailure: Error, Equatable, Sendable {
    case notSubsetOfGeneralAllowlist
    case generalAllowlistUnavailable
    case maintenanceFailed
}

package protocol GeneralAutomaticApplicationReading: Sendable {
    func generalAutomaticApplications() async throws -> Set<ApplicationIdentity>
}

package struct EmptyGeneralAutomaticApplicationReader:
    GeneralAutomaticApplicationReading {
    package init() {}

    package func generalAutomaticApplications() async throws
        -> Set<ApplicationIdentity> {
        []
    }
}

package enum OffDeviceAuthorizationStore {
    package static func valueForWrite(
        requested: Set<ApplicationIdentity>,
        generalAllowlist: Set<ApplicationIdentity>,
        privacyClass: DestinationPrivacyClass
    ) throws -> Set<ApplicationIdentity> {
        guard requested.isSubset(of: generalAllowlist) else {
            throw ProviderAuthorizationFailure.notSubsetOfGeneralAllowlist
        }
        switch privacyClass {
        case .localNetwork, .cloud:
            return requested
        case .localOnDevice:
            return []
        case .unresolvedOrChanged:
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    package static func valueForRead(
        persisted: Set<ApplicationIdentity>,
        privacyClass: DestinationPrivacyClass
    ) throws -> Set<ApplicationIdentity> {
        switch privacyClass {
        case .localNetwork, .cloud:
            return persisted
        case .localOnDevice:
            return []
        case .unresolvedOrChanged:
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    package static func effectiveValue(
        persisted: Set<ApplicationIdentity>,
        generalAllowlist: Set<ApplicationIdentity>,
        privacyClass: DestinationPrivacyClass
    ) throws -> Set<ApplicationIdentity> {
        try valueForRead(
            persisted: persisted,
            privacyClass: privacyClass
        ).intersection(generalAllowlist)
    }
}
