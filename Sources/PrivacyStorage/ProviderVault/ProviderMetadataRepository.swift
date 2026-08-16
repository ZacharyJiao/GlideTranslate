import Darwin
import Foundation
import SharedSupport

package enum ProviderMetadataPersistenceFailure: Error, Sendable {
    case durabilityUncertain(authoritative: ProviderMetadataEnvelope)
    case durabilityUncertainReloadFailed
}

package protocol ProviderMetadataPersisting: Sendable {
    func load() async throws -> ProviderMetadataEnvelope
    func install(_ envelope: ProviderMetadataEnvelope) async throws
    func delete() async throws
}

package extension ProviderMetadataPersisting {
    func delete() async throws {}
}

package actor ProviderMetadataRepository: ProviderMetadataPersisting {
    private let fileURL: URL
    private let installer: any AtomicDataInstalling
    private let directoryIdentity: SecureStoreDirectoryIdentity?

    package init(
        fileURL: URL,
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) {
        self.fileURL = SecureStorePath.canonicalFileURL(fileURL)
        self.installer = installer
        self.directoryIdentity = directoryIdentity
    }

    package func load() async throws -> ProviderMetadataEnvelope {
        do {
            let data = try Self.readRegularFileWithoutFollowingLinks(
                fileURL,
                directoryIdentity: directoryIdentity
            )
            guard let data else { return .empty }
            let envelope = try PropertyListDecoder().decode(
                ProviderMetadataEnvelope.self,
                from: data
            )
            return try envelope.validated()
        } catch let failure as SanitizedFailure {
            throw failure
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    package func install(_ envelope: ProviderMetadataEnvelope) async throws {
        let envelope = try envelope.validated()
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(envelope)
            guard data.count <= PrivacyStorageResourceLimits
                .providerMetadataEncodedBytes else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
            try installer.install(
                data,
                at: fileURL,
                expectedDirectoryIdentity: directoryIdentity
            )
        } catch AtomicInstallFailure.durabilityUncertain {
            let authoritative: ProviderMetadataEnvelope
            do {
                authoritative = try await load()
            } catch {
                throw ProviderMetadataPersistenceFailure
                    .durabilityUncertainReloadFailed
            }
            throw ProviderMetadataPersistenceFailure.durabilityUncertain(
                authoritative: authoritative
            )
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    package func delete() async throws {
        do {
            try SecureStoreFileRemover.removeRegularFileIfPresent(
                at: fileURL,
                expectedDirectoryIdentity: directoryIdentity
            )
        } catch {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }


    private static func readRegularFileWithoutFollowingLinks(
        _ url: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Data? {
        do {
            return try SecureStoreFileReader.readRegularFileIfPresent(
                at: url,
                expectedDirectoryIdentity: directoryIdentity,
                maximumByteCount: PrivacyStorageResourceLimits
                    .providerMetadataEncodedBytes
            )
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }
}
