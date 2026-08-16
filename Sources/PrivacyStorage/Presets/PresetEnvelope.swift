import Foundation
import SharedSupport

package enum PresetStoreFailure: Error, Equatable, Sendable {
    case invalidRepresentation
    case encryptionFailed
    case unrecoverable
}

package struct PresetEnvelope: Codable, Sendable {
    package let version: UInt16
    package let sealedCombined: Data

    package static let currentVersion: UInt16 = 1

    package func validated() throws -> Self {
        guard version == Self.currentVersion, !sealedCombined.isEmpty else {
            throw PresetStoreFailure.unrecoverable
        }
        return self
    }
}
