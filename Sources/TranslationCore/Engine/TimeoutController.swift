import SharedSupport

package protocol TimeoutControlling: Sendable {
    func arm(
        owner: UInt64,
        token: UInt64,
        phase: TranslationPhase,
        duration: Duration,
        handler: @escaping @Sendable (UInt64) async -> Void
    ) async -> Bool
    func disarm(owner: UInt64) async
}

package actor TimeoutController: TimeoutControlling {
    private let clock: any AppClock
    private var generation: UInt64 = 0
    private var owner: UInt64?
    private var phase: TranslationPhase?
    private var task: Task<Void, Never>?

    package init(clock: any AppClock) {
        self.clock = clock
    }

    package func arm(
        owner: UInt64,
        token: UInt64,
        phase: TranslationPhase,
        duration: Duration,
        handler: @escaping @Sendable (UInt64) async -> Void
    ) -> Bool {
        if let currentOwner = self.owner, owner < currentOwner {
            return false
        }
        generation &+= 1
        let capturedGeneration = generation
        self.owner = owner
        self.phase = phase
        task?.cancel()
        task = Task { [clock] in
            do {
                try await clock.sleep(for: duration)
                await self.fire(
                    owner: owner,
                    token: token,
                    generation: capturedGeneration,
                    phase: phase,
                    handler: handler
                )
            } catch {
                return
            }
        }
        return true
    }

    package func disarm(owner: UInt64) {
        guard self.owner == owner else { return }
        generation &+= 1
        self.owner = nil
        phase = nil
        task?.cancel()
        task = nil
    }

    private func fire(
        owner capturedOwner: UInt64,
        token: UInt64,
        generation capturedGeneration: UInt64,
        phase capturedPhase: TranslationPhase,
        handler: @escaping @Sendable (UInt64) async -> Void
    ) async {
        guard owner == capturedOwner,
              generation == capturedGeneration,
              phase == capturedPhase
        else {
            return
        }
        task = nil
        await handler(token)
    }
}
