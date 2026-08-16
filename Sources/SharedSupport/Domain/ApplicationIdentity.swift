import Foundation

public struct ApplicationIdentity: Hashable, Sendable, Codable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
}
