import Darwin
import Foundation
import SharedSupport

package enum AtomicInstallFailure: Error, Equatable, Sendable {
    case invalidDestination
    case writeFailed
    case durabilityUncertain
}

package protocol AtomicDataInstalling: Sendable {
    func install(_ data: Data, at destination: URL) throws
    func install(
        _ data: Data,
        at destination: URL,
        expectedDirectoryIdentity: SecureStoreDirectoryIdentity?
    ) throws
}

package extension AtomicDataInstalling {
    func install(
        _ data: Data,
        at destination: URL,
        expectedDirectoryIdentity: SecureStoreDirectoryIdentity?
    ) throws {
        try expectedDirectoryIdentity?.validateCurrentDirectory(
            at: destination.deletingLastPathComponent()
        )
        try install(data, at: destination)
    }
}

package struct AtomicInstallerHooks: @unchecked Sendable {
    package var beforeExistingSwap: ((URL) throws -> Void)?
    package var failFileSync: Bool
    package var failDirectorySync: Bool
    package var failRollbackSwap: Bool
    package var failRollbackSync: Bool

    package init(
        beforeExistingSwap: ((URL) throws -> Void)? = nil,
        failFileSync: Bool = false,
        failDirectorySync: Bool = false,
        failRollbackSwap: Bool = false,
        failRollbackSync: Bool = false
    ) {
        self.beforeExistingSwap = beforeExistingSwap
        self.failFileSync = failFileSync
        self.failDirectorySync = failDirectorySync
        self.failRollbackSwap = failRollbackSwap
        self.failRollbackSync = failRollbackSync
    }

    package static let none = AtomicInstallerHooks()
}

package struct SameDirectoryAtomicInstaller: AtomicDataInstalling {
    private let hooks: AtomicInstallerHooks

    package init(hooks: AtomicInstallerHooks = .none) {
        self.hooks = hooks
    }

    package func install(_ data: Data, at destination: URL) throws {
        try install(
            data,
            at: destination,
            expectedDirectoryIdentity: nil
        )
    }

    package func install(
        _ data: Data,
        at destination: URL,
        expectedDirectoryIdentity: SecureStoreDirectoryIdentity?
    ) throws {
        let destination = SecureStorePath.canonicalFileURL(destination)
        let parent = destination.deletingLastPathComponent()
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty else {
            throw AtomicInstallFailure.invalidDestination
        }

        let directoryFD: Int32
        do {
            if expectedDirectoryIdentity != nil {
                guard let existing = try SecureStoreDirectoryPreparer
                    .openExistingPrivateDirectory(parent) else {
                    throw SecureStoreFileRemovalFailure.removalFailed
                }
                directoryFD = existing
            } else {
                directoryFD = try SecureStoreDirectoryPreparer
                    .openPreparedDirectory(parent)
            }
            try expectedDirectoryIdentity?.validate(directoryFD)
        } catch {
            throw AtomicInstallFailure.writeFailed
        }
        defer { close(directoryFD) }

        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw AtomicInstallFailure.writeFailed }
        var installed = false
        defer {
            close(temporaryFD)
            if !installed { unlinkat(directoryFD, temporaryName, 0) }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                guard let base = rawBuffer.baseAddress else { break }
                let written = Darwin.write(
                    temporaryFD,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written > 0 else { throw AtomicInstallFailure.writeFailed }
                offset += written
            }
        }
        guard fchmod(temporaryFD, mode_t(0o600)) == 0,
              !hooks.failFileSync,
              fsync(temporaryFD) == 0 else {
            throw AtomicInstallFailure.writeFailed
        }

        var status = stat()
        let destinationStatus = fstatat(
            directoryFD,
            destinationName,
            &status,
            AT_SYMLINK_NOFOLLOW
        )
        if destinationStatus == 0 {
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw AtomicInstallFailure.invalidDestination
            }
            let originalDevice = status.st_dev
            let originalInode = status.st_ino
            try hooks.beforeExistingSwap?(destination)
            guard renameatx_np(
                directoryFD,
                temporaryName,
                directoryFD,
                destinationName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw AtomicInstallFailure.writeFailed
            }
            var displaced = stat()
            let identityMatches = fstatat(
                directoryFD,
                temporaryName,
                &displaced,
                AT_SYMLINK_NOFOLLOW
            ) == 0
                && displaced.st_dev == originalDevice
                && displaced.st_ino == originalInode
            guard identityMatches else {
                guard !hooks.failRollbackSwap,
                      renameatx_np(
                        directoryFD,
                        temporaryName,
                        directoryFD,
                        destinationName,
                        UInt32(RENAME_SWAP)
                      ) == 0 else {
                    // Ownership of the displaced name is no longer provable;
                    // preserve both namespace entries for recovery.
                    installed = true
                    throw AtomicInstallFailure.durabilityUncertain
                }
                guard !hooks.failRollbackSync,
                      fsync(directoryFD) == 0 else {
                    throw AtomicInstallFailure.durabilityUncertain
                }
                throw AtomicInstallFailure.writeFailed
            }
            guard unlinkat(directoryFD, temporaryName, 0) == 0 else {
                throw AtomicInstallFailure.durabilityUncertain
            }
        } else {
            guard errno == ENOENT else { throw AtomicInstallFailure.writeFailed }
            guard renameatx_np(
                directoryFD,
                temporaryName,
                directoryFD,
                destinationName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw AtomicInstallFailure.writeFailed
            }
        }
        installed = true

        guard !hooks.failDirectorySync, fsync(directoryFD) == 0 else {
            throw AtomicInstallFailure.durabilityUncertain
        }
    }
}
