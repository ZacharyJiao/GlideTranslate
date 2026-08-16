import CryptoKit
import Darwin
import Foundation
import SharedSupport

package actor EncryptedCustomPresetPersistence: CustomPresetPersistence {
    private static let processAuthorityLock = NSLock()
    private static let version: UInt16 = 1
    private static let account = "v1"
    private static let aad = Data("glidetranslate.private-presets.v1".utf8)
    private static let maximumPresetCount = 100
    private static let maximumNameLength = 80
    private static let maximumExplanationLength = 8_000
    private static let maximumTemplateLength = 8_000

    private let fileURL: URL
    private let keyStore: any SymmetricKeyStoring
    private let installer: any AtomicDataInstalling
    private let directoryIdentity: SecureStoreDirectoryIdentity?
    private let service: String
    private var presets: [CustomPreset]
    private var keyData: Data?
    private var usable = true

    private init(
        fileURL: URL,
        keyStore: any SymmetricKeyStoring,
        installer: any AtomicDataInstalling,
        directoryIdentity: SecureStoreDirectoryIdentity?,
        service: String,
        presets: [CustomPreset],
        keyData: Data?,
        usable: Bool = true
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.installer = installer
        self.directoryIdentity = directoryIdentity
        self.service = service
        self.presets = presets
        self.keyData = keyData
        self.usable = usable
    }

    package static func open(
        fileURL: URL,
        keyStore: any SymmetricKeyStoring = SymmetricKeyStore(),
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        service: String = "com.zaryolabs.GlideTranslate.private-presets-key"
    ) throws -> EncryptedCustomPresetPersistence {
        let fileURL = SecureStorePath.canonicalFileURL(fileURL)
        let loaded = try withAuthorityLock(
            for: fileURL,
            directoryIdentity: directoryIdentity
        ) {
            try load(
                fileURL: fileURL,
                keyStore: keyStore,
                service: service,
                directoryIdentity: directoryIdentity
            )
        }
        return EncryptedCustomPresetPersistence(
            fileURL: fileURL,
            keyStore: keyStore,
            installer: installer,
            directoryIdentity: directoryIdentity,
            service: service,
            presets: loaded.presets,
            keyData: loaded.keyData
        )
    }

    package static func openResettable(
        fileURL: URL,
        keyStore: any SymmetricKeyStoring = SymmetricKeyStore(),
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        service: String = "com.zaryolabs.GlideTranslate.private-presets-key"
    ) -> EncryptedCustomPresetPersistence {
        let fileURL = SecureStorePath.canonicalFileURL(fileURL)
        do {
            return try open(
                fileURL: fileURL,
                keyStore: keyStore,
                installer: installer,
                directoryIdentity: directoryIdentity,
                service: service
            )
        } catch {
            return EncryptedCustomPresetPersistence(
                fileURL: fileURL,
                keyStore: keyStore,
                installer: installer,
                directoryIdentity: directoryIdentity,
                service: service,
                presets: [],
                keyData: nil,
                usable: false
            )
        }
    }

    public func customPresets() async throws -> [CustomPreset] {
        try Self.withAuthorityLock(
            for: fileURL,
            directoryIdentity: directoryIdentity
        ) {
            try ensureUsable()
            try reloadAuthority()
            return presets
        }
    }

    public func save(_ preset: CustomPreset) async throws {
        try Self.withAuthorityLock(
            for: fileURL,
            directoryIdentity: directoryIdentity
        ) {
            try ensureUsable()
            try reloadAuthority()
            try Self.validateForWrite(preset)
            var candidate = presets
            if let index = candidate.firstIndex(where: { $0.id == preset.id }) {
                candidate[index] = preset
            } else {
                candidate.append(preset)
            }
            try Self.validateLoaded(candidate, failure: .invalidRepresentation)
            try install(candidate)
        }
    }

    public func delete(_ id: PresetID) async throws {
        try Self.withAuthorityLock(
            for: fileURL,
            directoryIdentity: directoryIdentity
        ) {
            try ensureUsable()
            try reloadAuthority()
            try Self.validateIdentifierForWrite(id)
            guard let index = presets.firstIndex(where: { $0.id == id }) else {
                throw PromptPresetFailure.presetNotFound
            }
            var candidate = presets
            candidate.remove(at: index)
            try install(candidate)
        }
    }

    package func deleteStoreAndKeyForReset() async throws {
        try Self.withAuthorityLock(
            for: fileURL,
            directoryIdentity: directoryIdentity
        ) {
            var failed = false
            do {
                try SecureStoreFileRemover.removeRegularFileIfPresent(
                    at: fileURL,
                    expectedDirectoryIdentity: directoryIdentity
                )
            } catch {
                failed = true
            }
            do {
                try keyStore.deleteKey(service: service, account: Self.account)
            } catch {
                failed = true
            }
            guard !failed else {
                usable = false
                throw PresetStoreFailure.unrecoverable
            }
            presets = []
            keyData = nil
            usable = true
        }
    }

    private func install(_ candidate: [CustomPreset]) throws {
        let keyMaterial: SymmetricKeyMaterial
        if let keyData {
            keyMaterial = SymmetricKeyMaterial(
                data: keyData,
                createdByCaller: false
            )
        } else {
            keyMaterial = try keyStore.readOrCreateKey(
                service: service,
                account: Self.account
            )
        }
        guard keyMaterial.data.count == 32 else {
            throw PresetStoreFailure.unrecoverable
        }
        let outer: Data
        do {
            outer = try Self.encode(candidate, using: keyMaterial.data)
        } catch {
            try discardNewKeyIfNeeded(keyMaterial.createdByCaller)
            throw error
        }

        do {
            try installer.install(
                outer,
                at: fileURL,
                expectedDirectoryIdentity: directoryIdentity
            )
        } catch AtomicInstallFailure.durabilityUncertain {
            do {
                try reloadAuthority()
            } catch {
                usable = false
            }
            throw PresetStoreFailure.unrecoverable
        } catch {
            try discardNewKeyIfNeeded(keyMaterial.createdByCaller)
            throw PresetStoreFailure.unrecoverable
        }

        presets = candidate
        keyData = keyMaterial.data
    }

    private func discardNewKeyIfNeeded(_ createdKey: Bool) throws {
        guard createdKey else { return }
        do {
            try keyStore.deleteKey(service: service, account: Self.account)
        } catch {
            usable = false
            throw PresetStoreFailure.unrecoverable
        }
    }

    private func ensureUsable() throws {
        guard usable else { throw PresetStoreFailure.unrecoverable }
    }

    private func reloadAuthority() throws {
        let hadEstablishedAuthority = keyData != nil
        let authoritative = try Self.load(
            fileURL: fileURL,
            keyStore: keyStore,
            service: service,
            directoryIdentity: directoryIdentity
        )
        guard !hadEstablishedAuthority || authoritative.keyData != nil else {
            usable = false
            throw PresetStoreFailure.unrecoverable
        }
        presets = authoritative.presets
        keyData = authoritative.keyData
    }

    private static func withAuthorityLock<T>(
        for fileURL: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        _ operation: () throws -> T
    ) throws -> T {
        processAuthorityLock.lock()
        defer { processAuthorityLock.unlock() }

        let parent = fileURL.deletingLastPathComponent()
        let directoryDescriptor: Int32
        do {
            if directoryIdentity != nil {
                guard let existing = try SecureStoreDirectoryPreparer
                    .openExistingPrivateDirectory(parent) else {
                    throw SecureStoreFileRemovalFailure.removalFailed
                }
                directoryDescriptor = existing
            } else {
                directoryDescriptor = try SecureStoreDirectoryPreparer
                    .openPreparedDirectory(parent)
            }
            try directoryIdentity?.validate(directoryDescriptor)
        } catch {
            throw PresetStoreFailure.unrecoverable
        }
        defer { close(directoryDescriptor) }
        let lockName = ".\(fileURL.lastPathComponent).authority.lock"
        let descriptor = Darwin.openat(
            directoryDescriptor,
            lockName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw PresetStoreFailure.unrecoverable
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & mode_t(0o077)) == 0 else {
            throw PresetStoreFailure.unrecoverable
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw PresetStoreFailure.unrecoverable
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func load(
        fileURL: URL,
        keyStore: any SymmetricKeyStoring,
        service: String,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> (presets: [CustomPreset], keyData: Data?) {
        do {
            let fileData = try readRegularFileWithoutFollowingLinks(
                fileURL,
                directoryIdentity: directoryIdentity
            )
            let keyData = try keyStore.readKey(service: service, account: account)
            guard let fileData else {
                guard keyData == nil else { throw PresetStoreFailure.unrecoverable }
                return ([], nil)
            }
            guard let keyData, keyData.count == 32 else {
                throw PresetStoreFailure.unrecoverable
            }
            let envelope = try PropertyListDecoder().decode(
                PresetEnvelope.self,
                from: fileData
            ).validated()
            let box = try AES.GCM.SealedBox(combined: envelope.sealedCombined)
            var plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: keyData),
                authenticating: aad
            )
            defer { plaintext.resetBytes(in: plaintext.indices) }
            var decoded = try PropertyListDecoder().decode(
                [CustomPreset].self,
                from: plaintext
            )
            defer { decoded.removeAll(keepingCapacity: false) }
            try validateLoaded(decoded, failure: .unrecoverable)
            return (decoded, keyData)
        } catch let failure as PresetStoreFailure {
            throw failure
        } catch {
            throw PresetStoreFailure.unrecoverable
        }
    }

    private static func encode(
        _ candidate: [CustomPreset],
        using keyData: Data
    ) throws -> Data {
        var plaintext: Data
        do {
            plaintext = try PropertyListEncoder().encode(candidate)
        } catch {
            throw PresetStoreFailure.encryptionFailed
        }
        defer { plaintext.resetBytes(in: plaintext.indices) }

        let combined: Data
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: keyData),
                authenticating: aad
            )
            guard let value = box.combined else {
                throw PresetStoreFailure.encryptionFailed
            }
            combined = value
        } catch let failure as PresetStoreFailure {
            throw failure
        } catch {
            throw PresetStoreFailure.encryptionFailed
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            let data = try encoder.encode(PresetEnvelope(
                version: version,
                sealedCombined: combined
            ))
            guard data.count <= PrivacyStorageResourceLimits
                .customPresetsEncodedBytes else {
                throw PresetStoreFailure.encryptionFailed
            }
            return data
        } catch {
            throw PresetStoreFailure.encryptionFailed
        }
    }

    private static func validateForWrite(_ preset: CustomPreset) throws {
        try validateIdentifierForWrite(preset.id)
        guard preset.name.count <= maximumNameLength,
              preset.explanation.count <= maximumExplanationLength,
              preset.template.count <= maximumTemplateLength,
              preset.name.utf8.count <= maximumNameLength * 4,
              preset.explanation.utf8.count <= maximumExplanationLength * 4,
              preset.template.utf8.count <= maximumTemplateLength * 4 else {
            throw PresetStoreFailure.invalidRepresentation
        }
    }

    private static func validateIdentifierForWrite(_ id: PresetID) throws {
        guard id.rawValue.hasPrefix("custom-") else {
            throw PromptPresetFailure.immutableBuiltIn
        }
        guard isValidCustomIdentifier(id) else {
            throw PromptPresetFailure.invalidCustomIdentifier
        }
    }

    private static func validateLoaded(
        _ values: [CustomPreset],
        failure: PresetStoreFailure
    ) throws {
        guard values.count <= maximumPresetCount,
              Set(values.map(\.id)).count == values.count else {
            throw failure
        }
        for value in values {
            guard isValidCustomIdentifier(value.id),
                  value.name.count <= maximumNameLength,
                  value.explanation.count <= maximumExplanationLength,
                  value.template.count <= maximumTemplateLength,
                  value.name.utf8.count <= maximumNameLength * 4,
                  value.explanation.utf8.count <= maximumExplanationLength * 4,
                  value.template.utf8.count <= maximumTemplateLength * 4 else {
                throw failure
            }
        }
    }

    private static func isValidCustomIdentifier(_ id: PresetID) -> Bool {
        let prefix = "custom-"
        guard id.rawValue.hasPrefix(prefix) else { return false }
        let suffix = String(id.rawValue.dropFirst(prefix.count))
        return suffix == suffix.lowercased() && UUID(uuidString: suffix) != nil
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
                    .customPresetsEncodedBytes
            )
        } catch {
            throw PresetStoreFailure.unrecoverable
        }
    }
}
