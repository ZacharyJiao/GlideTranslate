import SharedSupport

package enum PrivacyStorageResourceLimits {
    package static let preferencesEncodedBytes = 512 * 1_024
    package static let providerMetadataEncodedBytes = 2 * 1_024 * 1_024
    package static let customPresetsEncodedBytes = 4 * 1_024 * 1_024
    package static let historyEnvelopeEncodedBytes = 5 * 1_024 * 1_024

    package static let applicationCount = 10_000
    package static let applicationIdentifierUTF8Bytes = 1_024
    package static let applicationDisplayNameUTF8Bytes = 1_024
    package static let providerCount = 100
    package static let providerEndpointUTF8Bytes = 4_096
    package static let providerModelUTF8Bytes = 1_024
    package static let providerCleanupAccountCount = 16
    package static let historySourceUTF8Bytes = 80_000
    package static let historyResultUTF8Bytes = 4 * 1_024 * 1_024
    package static let historyPresetIdentifierUTF8Bytes = 256

    package static func validateApplications<S: Sequence>(
        _ applications: S
    ) -> Bool where S.Element == ApplicationIdentity {
        var count = 0
        for application in applications {
            count += 1
            guard count <= applicationCount,
                  application.bundleIdentifier.utf8.count
                    <= applicationIdentifierUTF8Bytes,
                  application.displayName.utf8.count
                    <= applicationDisplayNameUTF8Bytes else {
                return false
            }
        }
        return true
    }
}
