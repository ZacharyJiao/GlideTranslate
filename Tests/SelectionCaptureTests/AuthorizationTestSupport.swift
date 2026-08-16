import CoreGraphics
import Foundation
import SharedSupport
@testable import SelectionCapture

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

final class StubForegroundReader: ForegroundApplicationReading, @unchecked Sendable {
    let count = LockedCounter()
    private let lock = NSLock()
    private var results: [Result<ForegroundApplicationContext, SelectionAuthorizationFailure>]

    init(_ results: [Result<ForegroundApplicationContext, SelectionAuthorizationFailure>]) {
        self.results = results
    }

    func current() async -> Result<ForegroundApplicationContext, SelectionAuthorizationFailure> {
        count.increment()
        return lock.withLock {
            results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

final class StubSystemReader: SystemSelectionReading, @unchecked Sendable {
    let count = LockedCounter()
    var result: Result<CapturedSelection, SelectionAuthorizationFailure>

    init(result: Result<CapturedSelection, SelectionAuthorizationFailure>) {
        self.result = result
    }

    func readSelection(
        from context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        count.increment()
        return result
    }
}

final class StubClipboardReader: ShortcutClipboardReading, @unchecked Sendable {
    let count = LockedCounter()
    var result: Result<CapturedSelection, SelectionAuthorizationFailure>

    init(result: Result<CapturedSelection, SelectionAuthorizationFailure>) {
        self.result = result
    }

    func readShortcutSelection() async
        -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        count.increment()
        return result
    }
}

final class StubSnapshotReader: ProviderSnapshotReading, @unchecked Sendable {
    let count = LockedCounter()
    var result: Result<ProviderDestinationSnapshot, SanitizedFailure>

    init(_ snapshot: ProviderDestinationSnapshot) {
        result = .success(snapshot)
    }

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        count.increment()
        return result
    }
}

actor SuspendingSnapshotReader: ProviderSnapshotReading {
    private var continuation: CheckedContinuation<
        Result<ProviderDestinationSnapshot, SanitizedFailure>, Never
    >?
    private(set) var started = false

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(
        with result: Result<ProviderDestinationSnapshot, SanitizedFailure>
    ) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

actor SuspendingSystemReader: SystemSelectionReading {
    private var continuation: CheckedContinuation<
        Result<CapturedSelection, SelectionAuthorizationFailure>, Never
    >?
    private(set) var started = false

    func readSelection(
        from context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(
        with result: Result<CapturedSelection, SelectionAuthorizationFailure>
    ) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

struct PassThroughSelectionFilter: CapturedSelectionFiltering {
    func filter(
        _ raw: String,
        limit: Int
    ) -> Result<String, SelectionAuthorizationFailure> {
        raw.isEmpty ? .failure(.noValidSelection) : .success(raw)
    }
}

struct TestDuplicateChecker: DuplicateSelectionChecking {
    private(set) var reserved = Set<DuplicateReservation>()

    mutating func reserveIfNew(
        text: String,
        application: ApplicationIdentity
    ) -> DuplicateReservation? {
        let reservation = DuplicateReservation(id: UUID())
        reserved.insert(reservation)
        return reservation
    }

    mutating func commit(_ reservation: DuplicateReservation) {
        reserved.remove(reservation)
    }

    mutating func cancel(_ reservation: DuplicateReservation) {
        reserved.remove(reservation)
    }
}

struct RecordingDuplicateChecker: DuplicateSelectionChecking {
    let reservations: LockedCounter
    let commits: LockedCounter
    let cancellations: LockedCounter

    mutating func reserveIfNew(
        text: String,
        application: ApplicationIdentity
    ) -> DuplicateReservation? {
        reservations.increment()
        return DuplicateReservation(id: UUID())
    }

    mutating func commit(_ reservation: DuplicateReservation) {
        commits.increment()
    }

    mutating func cancel(_ reservation: DuplicateReservation) {
        cancellations.increment()
    }
}

final class MintSpy: IntentMintObserving, @unchecked Sendable {
    let count = LockedCounter()
    func didMint() { count.increment() }
}

struct AuthorizationFixture {
    let app = ApplicationIdentity(
        bundleIdentifier: "invalid.example.authorization",
        displayName: "Fixture"
    )
    let context: ForegroundApplicationContext
    let expected: ProviderDestinationSnapshot
    let options: TranslationOptionsSnapshot
    let policy: CapturePolicySnapshot
    let foregroundReader: StubForegroundReader
    let systemReader: StubSystemReader
    let clipboardReader: StubClipboardReader
    let snapshotReader: StubSnapshotReader
    let mintSpy: MintSpy
    let gate: DefaultSelectionAuthorizationGate

    init(
        triggerPolicy: CapturePolicySnapshot? = nil,
        current: ProviderDestinationSnapshot? = nil,
        foregroundResults: [Result<ForegroundApplicationContext, SelectionAuthorizationFailure>]? = nil
    ) {
        context = ForegroundApplicationContext(
            application: app,
            processIdentifier: 42,
            activationSequence: 1
        )
        expected = ProviderDestinationSnapshot.fixture()
        options = .fixture()
        policy = triggerPolicy ?? .authorizedMouse(application: app)
        foregroundReader = StubForegroundReader(
            foregroundResults ?? [.success(context), .success(context)]
        )
        systemReader = StubSystemReader(
            result: .success(CapturedSelection(text: "synthetic selection", displayRect: nil))
        )
        clipboardReader = StubClipboardReader(result: .failure(.noValidSelection))
        snapshotReader = StubSnapshotReader(current ?? expected)
        mintSpy = MintSpy()
        gate = DefaultSelectionAuthorizationGate(
            foregroundReader: foregroundReader,
            systemReader: systemReader,
            clipboardReader: clipboardReader,
            snapshotReader: snapshotReader,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: TestDuplicateChecker(),
            mintObserver: mintSpy
        )
    }
}

extension ProviderDestinationSnapshot {
    static func fixture(
        configurationID: ProviderConfigurationID = ProviderConfigurationID(),
        privacyClass: DestinationPrivacyClass = .localOnDevice,
        configurationRevision: UInt64 = 1,
        confirmationRevision: UInt64 = 1,
        origin: ProviderOrigin = ProviderOrigin(
            scheme: "https",
            host: "example.invalid",
            effectivePort: 443
        ),
        resolutionFingerprint: Set<String> = ["203.0.113.1"],
        protocolKind: ProviderProtocolKind = .ollamaNative,
        model: String = "synthetic-model"
    ) -> Self {
        Self.mintAfterResolution(
            configurationID: configurationID,
            privacyClass: privacyClass,
            configurationRevision: configurationRevision,
            confirmationRevision: confirmationRevision,
            origin: origin,
            resolutionFingerprint: resolutionFingerprint,
            protocolKind: protocolKind,
            model: model
        )
    }

    func changing(_ mutation: SnapshotMutation) -> Self {
        switch mutation {
        case .configurationRevision:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision + 1,
                            confirmationRevision: confirmationRevision,
                            origin: origin, resolutionFingerprint: resolutionFingerprint,
                            protocolKind: protocolKind, model: model)
        case .confirmationRevision:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision + 1,
                            origin: origin, resolutionFingerprint: resolutionFingerprint,
                            protocolKind: protocolKind, model: model)
        case .origin:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision,
                            origin: ProviderOrigin(scheme: "https", host: "changed.example.invalid", effectivePort: 443),
                            resolutionFingerprint: resolutionFingerprint,
                            protocolKind: protocolKind, model: model)
        case .resolutionFingerprint:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision,
                            origin: origin, resolutionFingerprint: ["203.0.113.2"],
                            protocolKind: protocolKind, model: model)
        case .privacyClass:
            return .fixture(configurationID: configurationID, privacyClass: .cloud,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision,
                            origin: origin, resolutionFingerprint: resolutionFingerprint,
                            protocolKind: protocolKind, model: model)
        case .protocolKind:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision,
                            origin: origin, resolutionFingerprint: resolutionFingerprint,
                            protocolKind: .openAICompatible, model: model)
        case .model:
            return .fixture(configurationID: configurationID,
                            privacyClass: privacyClass,
                            configurationRevision: configurationRevision,
                            confirmationRevision: confirmationRevision,
                            origin: origin, resolutionFingerprint: resolutionFingerprint,
                            protocolKind: protocolKind, model: "changed-model")
        }
    }
}

enum SnapshotMutation: CaseIterable {
    case configurationRevision
    case confirmationRevision
    case origin
    case resolutionFingerprint
    case privacyClass
    case protocolKind
    case model
}

extension TranslationOptionsSnapshot {
    static func fixture() -> Self {
        Self(
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            preset: .mintAfterPromptValidation(
                id: PresetID(rawValue: "builtin-translate"),
                action: .translate,
                template: "Translate {text}"
            ),
            timeouts: .init(
                connection: .seconds(1),
                firstToken: .seconds(1),
                streamIdle: .seconds(1)
            )
        )
    }
}

extension CapturePolicySnapshot {
    static func authorizedMouse(application: ApplicationIdentity) -> Self {
        Self(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: false,
            generalAllowlist: [application],
            offDeviceAllowlist: [application],
            clipboardFallbackEnabled: false,
            selectionDebounceMilliseconds: 350,
            selectionCharacterLimit: 2_000
        )
    }
}

extension SelectionAuthorizationOutcome {
    var failure: SelectionAuthorizationFailure? {
        guard case .rejected(let failure) = self else { return nil }
        return failure
    }

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }

    var isManualInputRequired: Bool {
        if case .manualInputRequired = self { return true }
        return false
    }
}
