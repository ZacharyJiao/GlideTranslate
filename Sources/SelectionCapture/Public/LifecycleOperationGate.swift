import Foundation

package final class LifecycleOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func acquire() async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock {
                guard occupied else {
                    occupied = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    package func release() {
        let next = lock.withLock {
            guard !waiters.isEmpty else {
                occupied = false
                return Optional<CheckedContinuation<Void, Never>>.none
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
