import SharedSupport

package enum PrivacyStorageGraphLeaseFailure: Error {
    case retired
}

package actor PrivacyStorageGraphLease {
    private var retired = false
    private var activeOperations = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []

    package func begin() throws {
        guard !retired else { throw PrivacyStorageGraphLeaseFailure.retired }
        activeOperations += 1
    }

    package func end() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = retirementWaiters
        retirementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    package func retire() async {
        retired = true
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            retirementWaiters.append(continuation)
        }
    }

    package func withOperation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try begin()
        do {
            let result = try await operation()
            end()
            return result
        } catch {
            end()
            throw error
        }
    }
}

package struct GraphLeasedPreferencesStore: PreferencesStore {
    let base: any PreferencesStore
    let lease: PrivacyStorageGraphLease

    public func snapshot() async throws -> PreferencesSnapshot {
        do { return try await lease.withOperation { try await base.snapshot() } }
        catch is PrivacyStorageGraphLeaseFailure {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }

    public func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        do {
            try await lease.withOperation {
                try await base.update(transform)
            }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }
}

package struct GraphLeasedCustomPresetPersistence: CustomPresetPersistence {
    let base: any CustomPresetPersistence
    let lease: PrivacyStorageGraphLease

    public func customPresets() async throws -> [CustomPreset] {
        do {
            return try await lease.withOperation {
                try await base.customPresets()
            }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw PresetStoreFailure.unrecoverable
        }
    }

    public func save(_ preset: CustomPreset) async throws {
        do {
            try await lease.withOperation { try await base.save(preset) }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw PresetStoreFailure.unrecoverable
        }
    }

    public func delete(_ id: PresetID) async throws {
        do {
            try await lease.withOperation { try await base.delete(id) }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw PresetStoreFailure.unrecoverable
        }
    }
}

package struct GraphLeasedTranslationHistory: TranslationHistory {
    let base: any TranslationHistory
    let lease: PrivacyStorageGraphLease

    public func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome {
        do {
            return try await lease.withOperation {
                try await base.recordCompleted(
                    completion,
                    sourceApplication: sourceApplication
                )
            }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw HistoryFailure.unrecoverable
        }
    }

    public func search(_ query: HistoryQuery) async throws -> [HistorySummary] {
        do {
            return try await lease.withOperation { try await base.search(query) }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw HistoryFailure.unrecoverable
        }
    }

    public func performMaintenance() async throws {
        do {
            try await lease.withOperation { try await base.performMaintenance() }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw HistoryFailure.unrecoverable
        }
    }

    public func delete(_ id: TranslationRecordID) async throws {
        do {
            try await lease.withOperation { try await base.delete(id) }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw HistoryFailure.unrecoverable
        }
    }

    public func clearAll() async throws {
        do {
            try await lease.withOperation { try await base.clearAll() }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw HistoryFailure.unrecoverable
        }
    }
}
