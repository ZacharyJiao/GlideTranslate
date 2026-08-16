import Foundation

public protocol AppClock: Sendable {
    var now: ContinuousClock.Instant { get }
    var date: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemAppClock: AppClock {
    private let clock = ContinuousClock()

    public init() {}

    public var now: ContinuousClock.Instant { clock.now }
    public var date: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
