import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

private enum CredentialEvent: Equatable {
    case destinationRevalidated
    case keychainRead
    case credentialApplied
    case requestOpened
    case leaseDestroyed
}

private final class CredentialEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialEvent] = []

    func append(_ event: CredentialEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func snapshot() -> [CredentialEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct RecordingLeaseObserver: ProviderCredentialLeaseObserving {
    let recorder: CredentialEventRecorder
    func destinationRevalidated() { recorder.append(.destinationRevalidated) }
    func leaseDestroyed() { recorder.append(.leaseDestroyed) }
}

private actor LeaseCredentialStore: ProviderCredentialStoring {
    private var values: [UUID: Data]
    private var reads = 0
    private let recorder: CredentialEventRecorder
    private let failRead: Bool
    private let readGate: AsyncTestGate?

    init(
        account: UUID,
        value: Data = Data("synthetic-secret".utf8),
        recorder: CredentialEventRecorder,
        failRead: Bool = false,
        readGate: AsyncTestGate? = nil
    ) {
        values = [account: value]
        self.recorder = recorder
        self.failRead = failRead
        self.readGate = readGate
    }

    func add(
        _ credential: borrowing SensitiveCredentialInput,
        account: UUID
    ) async throws {
        values[account] = Data(credential.value.utf8)
    }

    func delete(account: UUID) async throws {
        values.removeValue(forKey: account)
    }

    func read(account: UUID) async throws -> Data {
        reads += 1
        recorder.append(.keychainRead)
        if let readGate { await readGate.enterAndWait() }
        guard !failRead, let value = values[account] else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        return value
    }

    func readCount() -> Int { reads }
}

private actor AsyncTestGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct RecordingCredentialTarget: CredentialHeaderTarget, Sendable {
    let recorder: CredentialEventRecorder
    private(set) var byteCount = 0

    mutating func setAuthorizationCredential(
        _ credential: borrowing CredentialHeaderValue
    ) {
        byteCount = credential.withUnsafeBytes(\.count)
        recorder.append(.credentialApplied)
    }
}

final class CredentialLeaseTests: XCTestCase {
    func testCredentialIsReadAndAppliedOnlyInsideAcceptedRequestScope() async throws {
        let fixture = try await makeCredentialFixture()
        let result = try await fixture.vault.withCredentialLease(
            fixture.expected
        ) { lease in
            var target = RecordingCredentialTarget(recorder: fixture.recorder)
            lease.apply(to: &target)
            fixture.recorder.append(.requestOpened)
            return target.byteCount
        }
        XCTAssertEqual(result, Data("synthetic-secret".utf8).count)
        XCTAssertEqual(fixture.recorder.snapshot(), [
            .destinationRevalidated,
            .keychainRead,
            .credentialApplied,
            .requestOpened,
            .leaseDestroyed
        ])
        let reads = await fixture.credentials.readCount()
        XCTAssertEqual(reads, 1)
    }

    func testEveryStorageOwnedDriftRejectsBeforeCredentialRead() async throws {
        enum Drift: CaseIterable {
            case id, configurationRevision, confirmationRevision
            case protocolKind, model, confirmedClass, origin, inactive, unresolved
        }
        for drift in Drift.allCases {
            var record = credentialRecord()
            var expected = credentialSnapshot()
            switch drift {
            case .id:
                expected = credentialSnapshot(id: ProviderConfigurationID())
            case .configurationRevision:
                record.configurationRevision += 1
            case .confirmationRevision:
                record.confirmationRevision += 1
            case .protocolKind:
                record.protocolKind = .ollamaNative
            case .model:
                record.model = "changed"
            case .confirmedClass:
                record.confirmedClass = .localNetwork
            case .origin:
                record.endpoint = URL(string: "https://changed.invalid/v1")!
            case .inactive:
                record.state = .deletionPending
            case .unresolved:
                expected = credentialSnapshot(privacyClass: .unresolvedOrChanged)
            }
            let fixture = try await makeCredentialFixture(record: record, expected: expected)
            do {
                _ = try await fixture.vault.withCredentialLease(expected) { _ in 1 }
                XCTFail("Expected drift rejection for \(drift)")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .destinationReconfirmationRequired,
                    "\(drift)"
                )
            }
            let reads = await fixture.credentials.readCount()
            XCTAssertEqual(reads, 0, "\(drift)")
            XCTAssertTrue(fixture.recorder.snapshot().isEmpty, "\(drift)")
        }
    }

    func testCanonicalOriginsAcceptedByPreflightRemainAcceptedByLease() async throws {
        let loopback = try await makeCredentialFixture(
            record: credentialRecord(
                endpoint: URL(string: "http://[::1]/v1")!,
                confirmedClass: nil
            ),
            expected: credentialSnapshot(
                privacyClass: .localOnDevice,
                origin: ProviderOrigin(
                    scheme: "http",
                    host: "::1",
                    effectivePort: 80
                )
            )
        )
        _ = try await loopback.vault.withCredentialLease(loopback.expected) { _ in 1 }
        let loopbackReads = await loopback.credentials.readCount()
        XCTAssertEqual(loopbackReads, 1)

        let namedLoopback = try await makeCredentialFixture(
            record: credentialRecord(
                endpoint: URL(string: "http://LOCALHOST./v1")!,
                confirmedClass: nil
            ),
            expected: credentialSnapshot(
                privacyClass: .localOnDevice,
                origin: ProviderOrigin(
                    scheme: "http",
                    host: "localhost",
                    effectivePort: 80
                )
            )
        )
        _ = try await namedLoopback.vault.withCredentialLease(
            namedLoopback.expected
        ) { _ in 1 }
        let namedLoopbackReads = await namedLoopback.credentials.readCount()
        XCTAssertEqual(namedLoopbackReads, 1)

        let trailingDot = try await makeCredentialFixture(
            record: credentialRecord(
                endpoint: URL(string: "https://EXAMPLE.INVALID.:443/v1")!
            ),
            expected: credentialSnapshot(
                origin: ProviderOrigin(
                    scheme: "https",
                    host: "example.invalid",
                    effectivePort: 443
                )
            )
        )
        _ = try await trailingDot.vault.withCredentialLease(trailingDot.expected) { _ in 1 }
        let trailingDotReads = await trailingDot.credentials.readCount()
        XCTAssertEqual(trailingDotReads, 1)

        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let scoped = try await makeCredentialFixture(
            record: credentialRecord(
                endpoint: URL(string: "http://[fe80::1%25\(scopeID)]:8080/v1")!,
                confirmedClass: .localNetwork
            ),
            expected: credentialSnapshot(
                privacyClass: .localNetwork,
                origin: ProviderOrigin(
                    scheme: "http",
                    host: "fe80::1%\(scopeID)",
                    effectivePort: 8080
                )
            )
        )
        _ = try await scoped.vault.withCredentialLease(scoped.expected) { _ in 1 }
        let scopedReads = await scoped.credentials.readCount()
        XCTAssertEqual(scopedReads, 1)
    }

    func testCancelledQueuedLeaseNeverReadsOrAppliesCredential() async throws {
        let gate = AsyncTestGate()
        let fixture = try await makeCredentialFixture()
        let holder = Task {
            try await fixture.vault.withCredentialLease(fixture.expected) { _ in
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let waiter = Task {
            try await fixture.vault.withCredentialLease(fixture.expected) { lease in
                var target = RecordingCredentialTarget(recorder: fixture.recorder)
                lease.apply(to: &target)
            }
        }
        waiter.cancel()
        await gate.release()
        try await holder.value

        do {
            try await waiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        let reads = await fixture.credentials.readCount()
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(fixture.recorder.snapshot().contains(.credentialApplied))
    }

    func testCancellationDuringCredentialReadNeverAppliesCredential() async throws {
        let gate = AsyncTestGate()
        let fixture = try await makeCredentialFixture(readGate: gate)
        let operation = Task {
            try await fixture.vault.withCredentialLease(fixture.expected) { lease in
                var target = RecordingCredentialTarget(recorder: fixture.recorder)
                lease.apply(to: &target)
            }
        }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()

        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        let reads = await fixture.credentials.readCount()
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(fixture.recorder.snapshot().contains(.credentialApplied))
    }

    func testCredentiallessConfigurationFailsWithoutKeychainRead() async throws {
        var record = credentialRecord()
        record.activeCredentialAccount = nil
        let fixture = try await makeCredentialFixture(record: record)
        do {
            _ = try await fixture.vault.withCredentialLease(fixture.expected) { _ in 1 }
            XCTFail("Expected credentialless rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidCredential)
        }
        let reads = await fixture.credentials.readCount()
        XCTAssertEqual(reads, 0)
    }

    func testReadAndOperationFailuresStillDestroyLeaseExactlyOnce() async throws {
        let failedRead = try await makeCredentialFixture(failRead: true)
        do {
            _ = try await failedRead.vault.withCredentialLease(failedRead.expected) { _ in 1 }
            XCTFail("Expected read failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .credentialStoreUnavailable)
        }
        XCTAssertEqual(failedRead.recorder.snapshot(), [
            .destinationRevalidated, .keychainRead
        ])

        let failedOperation = try await makeCredentialFixture()
        do {
            _ = try await failedOperation.vault.withCredentialLease(
                failedOperation.expected
            ) { lease in
                var target = RecordingCredentialTarget(
                    recorder: failedOperation.recorder
                )
                lease.apply(to: &target)
                throw SanitizedFailure.cancelled
            }
            XCTFail("Expected operation failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        XCTAssertEqual(failedOperation.recorder.snapshot(), [
            .destinationRevalidated,
            .keychainRead,
            .credentialApplied,
            .leaseDestroyed
        ])
    }
}

private let leaseID = ProviderConfigurationID()
private let leaseAccount = UUID()

private struct CredentialFixture {
    let vault: DefaultProviderVault
    let credentials: LeaseCredentialStore
    let recorder: CredentialEventRecorder
    let expected: ProviderDestinationSnapshot
}

private func makeCredentialFixture(
    record: ProviderConfigurationRecord = credentialRecord(),
    expected: ProviderDestinationSnapshot = credentialSnapshot(),
    failRead: Bool = false,
    readGate: AsyncTestGate? = nil
) async throws -> CredentialFixture {
    let recorder = CredentialEventRecorder()
    let credentials = LeaseCredentialStore(
        account: leaseAccount,
        recorder: recorder,
        failRead: failRead,
        readGate: readGate
    )
    let metadata = MemoryProviderMetadata(envelope: ProviderMetadataEnvelope(
        version: 1,
        records: [record],
        offDeviceAuthorizations: [record.id: []]
    ))
    let vault = try await DefaultProviderVault.open(
        metadata: metadata,
        credentials: credentials,
        leaseObserver: RecordingLeaseObserver(recorder: recorder)
    )
    return CredentialFixture(
        vault: vault,
        credentials: credentials,
        recorder: recorder,
        expected: expected
    )
}

private func credentialRecord(
    endpoint: URL = URL(string: "https://example.invalid/v1")!,
    confirmedClass: DestinationPrivacyClass? = .cloud
) -> ProviderConfigurationRecord {
    ProviderConfigurationRecord(
        id: leaseID,
        protocolKind: .openAICompatible,
        endpoint: endpoint,
        model: "model",
        confirmedClass: confirmedClass,
        configurationRevision: 7,
        confirmationRevision: 3,
        activeCredentialAccount: leaseAccount,
        pendingCredentialAccount: nil,
        cleanupCredentialAccounts: [],
        state: .active
    )
}

private func credentialSnapshot(
    id: ProviderConfigurationID = leaseID,
    privacyClass: DestinationPrivacyClass = .cloud,
    origin: ProviderOrigin = ProviderOrigin(
        scheme: "https",
        host: "example.invalid",
        effectivePort: 443
    )
) -> ProviderDestinationSnapshot {
    .mintAfterResolution(
        configurationID: id,
        privacyClass: privacyClass,
        configurationRevision: 7,
        confirmationRevision: 3,
        origin: origin,
        resolutionFingerprint: ["synthetic-fingerprint"],
        protocolKind: .openAICompatible,
        model: "model"
    )
}
