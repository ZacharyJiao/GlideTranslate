import Darwin
import Foundation

package enum SecureStoreFileRemovalFailure: Error, Equatable, Sendable {
    case invalidPath
    case removalFailed
}

package struct SecureStoreDirectoryIdentity: Hashable, Sendable {
    private let device: dev_t
    private let inode: ino_t

    package static func capturePrepared(at directory: URL) throws -> Self {
        let descriptor = try SecureStoreDirectoryPreparer
            .openPreparedDirectory(directory)
        defer { close(descriptor) }
        return try identity(of: descriptor)
    }

    package func validate(_ descriptor: Int32) throws {
        guard try Self.identity(of: descriptor) == self else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
    }

    package func validateCurrentDirectory(at directory: URL) throws {
        guard let descriptor = try SecureStoreDirectoryPreparer
            .openExistingPrivateDirectory(directory) else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        defer { close(descriptor) }
        try validate(descriptor)
    }

    private static func identity(of descriptor: Int32) throws -> Self {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        return Self(device: status.st_dev, inode: status.st_ino)
    }
}

package enum SecureStoreDirectoryPreparer {
    package static func prepare(_ directory: URL) throws {
        let descriptor = try openPreparedDirectory(directory)
        close(descriptor)
    }

    package static func openPreparedDirectory(_ directory: URL) throws -> Int32 {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/" else {
            throw SecureStoreFileRemovalFailure.invalidPath
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.isEmpty else {
                    throw SecureStoreFileRemovalFailure.invalidPath
                }
                var next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT {
                    guard mkdirat(current, component, mode_t(0o700)) == 0 else {
                        throw SecureStoreFileRemovalFailure.removalFailed
                    }
                    next = Darwin.openat(
                        current,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw SecureStoreFileRemovalFailure.removalFailed
                }
                close(current)
                current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == getuid(),
                  fchmod(current, mode_t(0o700)) == 0,
                  fstat(current, &status) == 0,
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    package static func openExistingPrivateDirectory(_ directory: URL) throws
        -> Int32? {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/" else {
            throw SecureStoreFileRemovalFailure.invalidPath
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.isEmpty else {
                    throw SecureStoreFileRemovalFailure.invalidPath
                }
                let next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT {
                    close(current)
                    return nil
                }
                guard next >= 0 else {
                    throw SecureStoreFileRemovalFailure.removalFailed
                }
                close(current)
                current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == getuid(),
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }
}

package enum SecureStorePath {
    package static func canonicalFileURL(_ fileURL: URL) -> URL {
        let components = fileURL.pathComponents
        guard components.count > 1 else { return fileURL }

        let firstComponent = components[1]
        let rootEntry = "/\(firstComponent)"
        var status = stat()
        guard lstat(rootEntry, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFLNK,
              status.st_uid == 0 else {
            return fileURL
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(rootEntry, &buffer, buffer.count - 1)
        guard count > 0 else { return fileURL }
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        let target = String(decoding: bytes, as: UTF8.self)
        var resolved = target.hasPrefix("/")
            ? URL(fileURLWithPath: target, isDirectory: true)
            : URL(fileURLWithPath: "/", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
        for component in components.dropFirst(2) {
            resolved.appendPathComponent(component)
        }
        return resolved
    }
}

package enum SecureStoreFileReader {
    package static func readRegularFileIfPresent(
        at fileURL: URL,
        expectedDirectoryIdentity: SecureStoreDirectoryIdentity? = nil,
        maximumByteCount: Int = .max
    ) throws -> Data? {
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw SecureStoreFileRemovalFailure.invalidPath
        }
        let openedParent = try SecureStoreDirectoryPreparer
            .openExistingPrivateDirectory(fileURL.deletingLastPathComponent())
        guard let parent = openedParent else {
            if expectedDirectoryIdentity != nil {
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            return nil
        }
        defer { close(parent) }
        try expectedDirectoryIdentity?.validate(parent)

        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_size >= 0,
              maximumByteCount > 0,
              status.st_size <= off_t(maximumByteCount) else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            guard data.count <= maximumByteCount - count else {
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

package enum SecureStoreFileRemover {
    @discardableResult
    package static func removeRegularFileIfPresent(
        at fileURL: URL,
        expectedDirectoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Bool {
        let parentURL = fileURL.deletingLastPathComponent()
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw SecureStoreFileRemovalFailure.invalidPath
        }
        let openedParent = try SecureStoreDirectoryPreparer
            .openExistingPrivateDirectory(parentURL)
        guard let parent = openedParent else {
            if expectedDirectoryIdentity != nil {
                throw SecureStoreFileRemovalFailure.removalFailed
            }
            return false
        }
        defer { close(parent) }
        try expectedDirectoryIdentity?.validate(parent)

        var status = stat()
        let result = fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW)
        if result != 0, errno == ENOENT { return false }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              unlinkat(parent, name, 0) == 0,
              fsync(parent) == 0 else {
            throw SecureStoreFileRemovalFailure.removalFailed
        }
        return true
    }

}
