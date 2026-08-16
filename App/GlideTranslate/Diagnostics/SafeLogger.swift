import ModelProviders
import OSLog
import SharedSupport

enum SafeLogRecord: Equatable, Sendable {
    case capture(CaptureOutcomeCategory)
    case providerHealth(ProviderHealthCategory)
    case providerDiagnostic(
        DestinationPrivacyClass,
        ProviderOutcomeCategory,
        durationMilliseconds: UInt64
    )
    case translation(SanitizedFailure?, durationMilliseconds: UInt64)
    case history(HistoryOutcomeCategory)
    case permission(AccessibilityPermissionCategory)
}

protocol SafeLogEmitting: Sendable {
    func emit(_ record: SafeLogRecord)
}

struct SafeLogger: Sendable {
    static let approvedSubsystem = "com.zaryolabs.GlideTranslate"

    private let emitter: any SafeLogEmitting

    init() {
        emitter = OSLogSafeLogEmitter()
    }

    init(emitter: any SafeLogEmitting) {
        self.emitter = emitter
    }

    func record(_ event: AppEvent) {
        switch event {
        case let .captureOutcome(outcome):
            emitter.emit(.capture(outcome))
        case let .providerHealth(health):
            emitter.emit(.providerHealth(health))
        case let .translationOutcome(failure, durationMilliseconds):
            emitter.emit(.translation(
                failure,
                durationMilliseconds: durationMilliseconds
            ))
        case let .historyOutcome(outcome):
            emitter.emit(.history(outcome))
        case let .permissionState(state):
            emitter.emit(.permission(state))
        }
    }

    func recordProviderDiagnostic(
        providerClass: DestinationPrivacyClass,
        outcome: ProviderOutcomeCategory,
        durationMilliseconds: UInt64
    ) {
        emitter.emit(.providerDiagnostic(
            providerClass,
            outcome,
            durationMilliseconds: durationMilliseconds
        ))
    }
}

private struct OSLogSafeLogEmitter: SafeLogEmitting {
    private let capture = Logger(
        subsystem: SafeLogger.approvedSubsystem,
        category: "capture"
    )
    private let provider = Logger(
        subsystem: SafeLogger.approvedSubsystem,
        category: "provider"
    )
    private let translation = Logger(
        subsystem: SafeLogger.approvedSubsystem,
        category: "translation"
    )
    private let storage = Logger(
        subsystem: SafeLogger.approvedSubsystem,
        category: "storage"
    )
    private let permission = Logger(
        subsystem: SafeLogger.approvedSubsystem,
        category: "permission"
    )

    func emit(_ record: SafeLogRecord) {
        switch record {
        case let .capture(outcome):
            capture.info(
                "capture_outcome=\(outcome.rawValue, privacy: .public)"
            )
        case let .providerHealth(health):
            provider.info(
                "provider_health=\(health.rawValue, privacy: .public)"
            )
        case let .providerDiagnostic(
            providerClass,
            outcome,
            durationMilliseconds
        ):
            provider.info(
                "provider_class=\(providerClass.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
            )
        case let .translation(failure, durationMilliseconds):
            if let failure {
                translation.info(
                    "translation_outcome=failed failure=\(failure.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            } else {
                translation.info(
                    "translation_outcome=succeeded duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            }
        case let .history(outcome):
            storage.info(
                "history_outcome=\(outcome.rawValue, privacy: .public)"
            )
        case let .permission(state):
            permission.info(
                "accessibility_permission=\(state.rawValue, privacy: .public)"
            )
        }
    }
}

struct AppProviderDiagnosticReporter: ProviderDiagnosticReporting {
    private let logger: SafeLogger

    init(logger: SafeLogger) {
        self.logger = logger
    }

    func record(_ event: ProviderDiagnosticEvent) async {
        logger.recordProviderDiagnostic(
            providerClass: event.providerClass,
            outcome: event.outcomeCategory,
            durationMilliseconds: event.durationMilliseconds
        )
    }
}
