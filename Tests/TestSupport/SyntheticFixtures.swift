import SharedSupport
import Foundation

public enum SyntheticFixtures {
    public static let application = ApplicationIdentity(
        bundleIdentifier: "invalid.example.synthetic",
        displayName: "Synthetic App"
    )
}

public extension CapturePolicySnapshot {
    static func fixture(
        master: Bool,
        mouseEnabled: Bool,
        keyboardEnabled: Bool,
        general: Set<ApplicationIdentity>,
        offDevice: Set<ApplicationIdentity>,
        clipboard: Bool
    ) -> Self {
        Self(
            automaticCaptureEnabled: master,
            mouseSelectionEnabled: mouseEnabled,
            keyboardSelectionEnabled: keyboardEnabled,
            generalAllowlist: general,
            offDeviceAllowlist: offDevice,
            clipboardFallbackEnabled: clipboard,
            selectionDebounceMilliseconds: 350,
            selectionCharacterLimit: 2_000
        )
    }
}

public final class ManualAppClock: AppClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var elapsed = Duration.zero
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public var now: ContinuousClock.Instant {
        lock.withLock { base.advanced(by: elapsed) }
    }

    public var date: Date {
        lock.withLock { Date(timeIntervalSince1970: elapsed.secondsValue) }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let deadline = now.advanced(by: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = lock.withLock {
                    if base.advanced(by: elapsed) >= deadline { return true }
                    waiters[id] = Waiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: Duration) async {
        let due: [Waiter] = lock.withLock {
            elapsed += duration
            let current = base.advanced(by: elapsed)
            let dueIDs = waiters.compactMap { key, waiter in
                waiter.deadline <= current ? key : nil
            }
            return dueIDs.compactMap { waiters.removeValue(forKey: $0) }
        }
        due.forEach { $0.continuation.resume() }
        await Task.yield()
    }

    public func waitForSleepers(_ count: Int) async {
        while lock.withLock({ waiters.count }) < count { await Task.yield() }
    }
}

private extension Duration {
    var secondsValue: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
