import SharedSupport

package actor SelectionDebouncer {
    private let delay: Duration
    private let clock: any AppClock
    private var generation: UInt64 = 0

    package init(delay: Duration, clock: any AppClock) {
        self.delay = delay
        self.clock = clock
    }

    package func submit(
        _ trigger: CaptureTrigger,
        emit: @escaping @Sendable (CaptureTrigger) async -> Void
    ) {
        generation &+= 1
        let submittedGeneration = generation
        Task {
            do { try await clock.sleep(for: delay) } catch { return }
            guard submittedGeneration == generation else { return }
            await emit(trigger)
        }
    }

    package func wait(for duration: Duration? = nil) async -> Bool {
        generation &+= 1
        let submittedGeneration = generation
        do {
            try await clock.sleep(for: duration ?? delay)
        } catch {
            return false
        }
        return submittedGeneration == generation && !Task.isCancelled
    }

    package func cancel() { generation &+= 1 }
}
