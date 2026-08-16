import Dispatch
import Foundation

private final class AXCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

package actor AXExecutionLane {
    private let queue = DispatchQueue(
        label: "com.zaryolabs.GlideTranslate.selection.ax",
        qos: .userInitiated
    )

    package func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let cancellation = AXCancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result(catching: operation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
