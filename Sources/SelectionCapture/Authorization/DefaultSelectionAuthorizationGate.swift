import CoreGraphics
import Foundation
import SharedSupport

package protocol SystemSelectionReading: Sendable {
    func readSelection(
        from context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure>
}

package protocol ShortcutClipboardReading: Sendable {
    func readShortcutSelection() async
        -> Result<CapturedSelection, SelectionAuthorizationFailure>
}

package protocol CapturedSelectionFiltering: Sendable {
    func filter(
        _ raw: String,
        limit: Int
    ) -> Result<String, SelectionAuthorizationFailure>
}

package protocol DuplicateSelectionChecking: Sendable {
    mutating func reserveIfNew(
        text: String,
        application: ApplicationIdentity
    ) -> DuplicateReservation?
    mutating func commit(_ reservation: DuplicateReservation)
    mutating func cancel(_ reservation: DuplicateReservation)
    mutating func reset()
}

package extension DuplicateSelectionChecking {
    mutating func reset() {}
}

package protocol ResettableSelectionAuthorizationGate:
    SelectionAuthorizationGate {
    func resetDuplicateState() async
}

package struct DuplicateReservation: Hashable, Sendable {
    package let id: UUID
}

package struct CapturedSelection: Equatable, Sendable {
    package let text: String
    package let displayRect: CGRect?
}

package protocol IntentMintObserving: Sendable {
    func didMint()
}

private struct NoOpMintObserver: IntentMintObserving {
    func didMint() {}
}

package actor DefaultSelectionAuthorizationGate:
    ResettableSelectionAuthorizationGate {
    private let foregroundReader: any ForegroundApplicationReading
    private let systemReader: any SystemSelectionReading
    private let clipboardReader: any ShortcutClipboardReading
    private let snapshotReader: any ProviderSnapshotReading
    private let selectionFilter: any CapturedSelectionFiltering
    private var duplicateChecker: any DuplicateSelectionChecking
    private let mintObserver: any IntentMintObserving

    package init(
        foregroundReader: any ForegroundApplicationReading,
        systemReader: any SystemSelectionReading,
        clipboardReader: any ShortcutClipboardReading,
        snapshotReader: any ProviderSnapshotReading,
        selectionFilter: any CapturedSelectionFiltering,
        duplicateChecker: any DuplicateSelectionChecking,
        mintObserver: any IntentMintObserving = NoOpMintObserver()
    ) {
        self.foregroundReader = foregroundReader
        self.systemReader = systemReader
        self.clipboardReader = clipboardReader
        self.snapshotReader = snapshotReader
        self.selectionFilter = selectionFilter
        self.duplicateChecker = duplicateChecker
        self.mintObserver = mintObserver
    }

    package func authorizeSystemSelection(
        trigger: CaptureTrigger,
        context: ForegroundApplicationContext,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome {
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        let preRead = PreReadPolicy.evaluate(
            trigger: trigger,
            application: context.application,
            policy: policy,
            privacyClass: provider.privacyClass
        )
        switch preRead {
        case .rejected(let failure):
            return .rejected(failure.authorizationFailure)
        case .manual:
            return .manualInputRequired
        case .accessibility, .accessibilityWithOptionalClipboard:
            break
        }

        let beforeReadResult = await foregroundReader.current()
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let beforeRead) = beforeReadResult,
              beforeRead == context else {
            return .rejected(.foregroundApplicationChanged)
        }

        let captured = await systemReader.readSelection(from: context)
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        let selection: CapturedSelection
        switch captured {
        case .success(let value):
            selection = value
        case .failure
            where trigger == .shortcut
                && preRead == .accessibilityWithOptionalClipboard:
            guard !Task.isCancelled else {
                return .rejected(.cancelled)
            }
            let clipboardResult = await clipboardReader.readShortcutSelection()
            guard !Task.isCancelled else {
                return .rejected(.cancelled)
            }
            switch clipboardResult {
            case .success(let value):
                selection = value
            case .failure:
                return .manualInputRequired
            }
        case .failure(let failure):
            return trigger == .shortcut
                ? .manualInputRequired
                : .rejected(failure)
        }

        let beforeFilteringResult = await foregroundReader.current()
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let beforeFiltering) = beforeFilteringResult,
              beforeFiltering == context else {
            return .rejected(.foregroundApplicationChanged)
        }
        guard case .success(let filteredText) = selectionFilter.filter(
            selection.text,
            limit: policy.selectionCharacterLimit
        ) else {
            return .rejected(.noValidSelection)
        }
        guard let reservation = duplicateChecker.reserveIfNew(
            text: filteredText,
            application: context.application
        ) else {
            return .rejected(.noValidSelection)
        }

        var reservationCommitted = false
        defer {
            if !reservationCommitted {
                duplicateChecker.cancel(reservation)
            }
        }

        let snapshotResult = await snapshotReader.currentSnapshot(
            for: provider.configurationID
        )
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let current) = snapshotResult else {
            return .rejected(.providerDestinationUnresolved)
        }
        switch SendAuthorizationPolicy.evaluate(expected: provider, current: current) {
        case .failure(let failure):
            return .rejected(failure)
        case .success:
            break
        }
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }

        let beforeMintResult = await foregroundReader.current()
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let beforeMint) = beforeMintResult,
              beforeMint == context else {
            return .rejected(.foregroundApplicationChanged)
        }

        let payload = AuthorizedTranslationPayload(
            text: filteredText,
            sourceApplication: context.application,
            options: options,
            provider: current,
            displayRect: selection.displayRect
        )
        mintObserver.didMint()
        let intent = AuthorizedTranslationIntent.mintAfterAuthorization(
            requestID: TranslationRequestID(),
            payload: payload
        )
        duplicateChecker.commit(reservation)
        reservationCommitted = true
        return .authorized(intent, .init(payload: payload))
    }

    package func authorizeManualSubmission(
        _ submission: ManualTranslationSubmission,
        policy: SendPolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome {
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard submission.providerConfigurationID == provider.configurationID,
              provider.configurationID == policy.expectedProvider.configurationID else {
            return .rejected(.providerChanged)
        }
        let snapshotResult = await snapshotReader.currentSnapshot(
            for: submission.providerConfigurationID
        )
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let current) = snapshotResult else {
            return .rejected(.providerDestinationUnresolved)
        }
        switch SendAuthorizationPolicy.evaluate(
            expected: policy.expectedProvider,
            current: current
        ) {
        case .failure(let failure):
            return .rejected(failure)
        case .success:
            break
        }
        guard provider == policy.expectedProvider else {
            return .rejected(.providerChanged)
        }
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }

        let payload = AuthorizedTranslationPayload(
            text: submission.text,
            sourceApplication: nil,
            options: submission.options,
            provider: current,
            displayRect: nil
        )
        mintObserver.didMint()
        let intent = AuthorizedTranslationIntent.mintAfterAuthorization(
            requestID: TranslationRequestID(),
            payload: payload
        )
        return .authorized(intent, .init(payload: payload))
    }

    package func resetDuplicateState() {
        duplicateChecker.reset()
    }
}

private extension PreReadFailure {
    var authorizationFailure: SelectionAuthorizationFailure {
        switch self {
        case .automaticCapturePaused: .automaticCapturePaused
        case .mouseCaptureDisabled: .mouseCaptureDisabled
        case .keyboardCaptureDisabled: .keyboardCaptureDisabled
        case .applicationNotAllowed: .applicationNotAllowed
        case .offDeviceApplicationNotAllowed: .offDeviceApplicationNotAllowed
        case .providerDestinationUnresolved: .providerDestinationUnresolved
        }
    }
}
