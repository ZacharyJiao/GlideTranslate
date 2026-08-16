import Foundation
import SharedSupport
import TranslationCore
import XCTest
@testable import GlideTranslate

final class SafeLoggerTests: XCTestCase {
    func testEventInventoryContainsOnlyClosedAssociatedValues() {
        let events: [AppEvent] = [
            .captureOutcome(.succeeded),
            .captureOutcome(.rejected),
            .captureOutcome(.timedOut),
            .captureOutcome(.cancelled),
            .providerHealth(.available),
            .providerHealth(.unavailable),
            .providerHealth(.reconfirmationRequired),
            .translationOutcome(nil, durationMilliseconds: 1),
            .translationOutcome(.providerProtocolFailure, durationMilliseconds: 2),
            .historyOutcome(.skippedDisabled),
            .historyOutcome(.stored),
            .historyOutcome(.removed),
            .historyOutcome(.unrecoverable),
            .permissionState(.granted),
            .permissionState(.denied)
        ]

        for event in events {
            switch event {
            case .captureOutcome:
                break
            case .providerHealth:
                break
            case .translationOutcome:
                break
            case .historyOutcome:
                break
            case .permissionState:
                break
            }
            assertContainsNoForbiddenRuntimeValue(event)
        }
    }

    func testLogsAndDiagnosticsExcludeRuntimeSensitiveMarkers() throws {
        let markers = [
            ["SYNTHETIC", "_SOURCE"].joined(),
            ["SYNTHETIC", "_RESULT"].joined(),
            ["SYNTHETIC", "_MODEL"].joined(),
            ["example", ".invalid/private"].joined()
        ]
        let emitter = CapturingSafeLogEmitter()
        let logger = SafeLogger(emitter: emitter)
        logger.record(.translationOutcome(
            .providerProtocolFailure,
            durationMilliseconds: 42
        ))
        logger.record(.providerHealth(.available))
        logger.recordProviderDiagnostic(
            providerClass: .cloud,
            outcome: .protocolFailure,
            durationMilliseconds: 43
        )

        let report = try makeReportBuilder().encodedPreview()
        let combined = emitter.bytes + report
        for marker in markers {
            XCTAssertNil(combined.range(of: Data(marker.utf8)))
        }
    }

    func testLoggerMapsEveryAppEventToOneClosedRecord() {
        let emitter = CapturingSafeLogEmitter()
        let logger = SafeLogger(emitter: emitter)

        logger.record(.captureOutcome(.timedOut))
        logger.record(.providerHealth(.unavailable))
        logger.record(.translationOutcome(
            .cancelled,
            durationMilliseconds: 9
        ))
        logger.record(.historyOutcome(.stored))
        logger.record(.permissionState(.denied))

        XCTAssertEqual(emitter.capturedRecords, [
            .capture(.timedOut),
            .providerHealth(.unavailable),
            .translation(.cancelled, durationMilliseconds: 9),
            .history(.stored),
            .permission(.denied)
        ])
        XCTAssertEqual(
            SafeLogger.approvedSubsystem,
            "com.zaryolabs.GlideTranslate"
        )
    }

    func testDiagnosticReportHasExactFixedSchemaAndValues() throws {
        let data = try makeReportBuilder().encodedPreview()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "schemaVersion",
            "appVersion",
            "osMajorVersion",
            "architecture",
            "accessibilityPermission",
            "defaultProviderClass",
            "componentHealth",
            "recentOutcomeCounts"
        ])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["appVersion"] as? String, "1.0")
        XCTAssertEqual(object["osMajorVersion"] as? Int, 15)
        XCTAssertEqual(object["architecture"] as? String, "arm64")
        XCTAssertEqual(object["accessibilityPermission"] as? String, "denied")
        XCTAssertEqual(object["defaultProviderClass"] as? String, "localOnDevice")
        XCTAssertEqual(
            object["componentHealth"] as? [String],
            ["captureOperational", "storageOperational"]
        )
        XCTAssertEqual(
            object["recentOutcomeCounts"] as? [String: Int],
            [
                "captureRejected": 0,
                "translationSucceeded": 3,
                "translationFailed": 1,
                "translationCancelled": 0,
                "historyStored": 0,
                "historyFailed": 0
            ]
        )
        XCTAssertTrue(json.hasPrefix("{\n"))
        let sortedKeys = [
            "accessibilityPermission",
            "appVersion",
            "architecture",
            "componentHealth",
            "defaultProviderClass",
            "osMajorVersion",
            "recentOutcomeCounts",
            "schemaVersion"
        ]
        let keyOffsets = try sortedKeys.map { key in
            try XCTUnwrap(json.range(of: "\"\(key)\"")?.lowerBound)
        }
        XCTAssertEqual(keyOffsets, keyOffsets.sorted())
    }

    func testDiagnosticReportDecoderRejectsMissingOutcomeCategoryKey() throws {
        let data = try makeReportBuilder().encodedPreview()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var counts = try XCTUnwrap(
            object["recentOutcomeCounts"] as? [String: Int]
        )
        counts.removeValue(forKey: "historyFailed")
        object["recentOutcomeCounts"] = counts
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(DiagnosticReport.self, from: malformed)
        )
    }

    func testDiagnosticReportDecoderRejectsExtraOutcomeCategoryKey() throws {
        let data = try makeReportBuilder().encodedPreview()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var counts = try XCTUnwrap(
            object["recentOutcomeCounts"] as? [String: Int]
        )
        counts["unexpectedOutcome"] = 1
        object["recentOutcomeCounts"] = counts
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(DiagnosticReport.self, from: malformed)
        )
    }

    func testDiagnosticReportRejectsFreeFormVersionAndInvalidCounts() {
        XCTAssertThrowsError(try DiagnosticReportBuilder(
            appVersion: ["private", "-model"].joined(),
            osMajorVersion: 15,
            architecture: .arm64,
            accessibilityPermission: .granted,
            defaultProviderClass: .cloud,
            componentHealth: [.providerOperational],
            recentOutcomeCounts: [.translationSucceeded: 1]
        )) { error in
            XCTAssertEqual(error as? DiagnosticReportError, .invalidAppVersion)
        }

        XCTAssertThrowsError(try DiagnosticReportBuilder(
            appVersion: "1.0",
            osMajorVersion: 15,
            architecture: .arm64,
            accessibilityPermission: .granted,
            defaultProviderClass: .cloud,
            componentHealth: [.providerOperational],
            recentOutcomeCounts: [.translationFailed: -1]
        )) { error in
            XCTAssertEqual(error as? DiagnosticReportError, .invalidOutcomeCount)
        }
    }

    private func makeReportBuilder() throws -> DiagnosticReportBuilder {
        try DiagnosticReportBuilder(
            appVersion: "1.0",
            osMajorVersion: 15,
            architecture: .arm64,
            accessibilityPermission: .denied,
            defaultProviderClass: .localOnDevice,
            componentHealth: [.captureOperational, .storageOperational],
            recentOutcomeCounts: [
                .translationSucceeded: 3,
                .translationFailed: 1
            ]
        )
    }

    private func assertContainsNoForbiddenRuntimeValue(
        _ value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbiddenTypeNames = [
            String(reflecting: String.self),
            String(reflecting: URL.self),
            String(reflecting: Data.self),
            String(reflecting: ApplicationIdentity.self),
            String(reflecting: CustomPreset.self),
            String(reflecting: TranslationRequest.self)
        ]
        let reflectedType = String(reflecting: type(of: value))
        XCTAssertFalse(
            forbiddenTypeNames.contains(reflectedType),
            "forbidden associated value type",
            file: file,
            line: line
        )
        for child in Mirror(reflecting: value).children {
            assertContainsNoForbiddenRuntimeValue(
                child.value,
                file: file,
                line: line
            )
        }
    }
}

private final class CapturingSafeLogEmitter: SafeLogEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SafeLogRecord] = []

    var bytes: Data {
        lock.withLock {
            Data(records.flatMap { Array(Self.render($0).utf8) })
        }
    }

    var capturedRecords: [SafeLogRecord] {
        lock.withLock { records }
    }

    func emit(_ record: SafeLogRecord) {
        lock.withLock {
            records.append(record)
        }
    }

    private static func render(_ record: SafeLogRecord) -> String {
        switch record {
        case let .capture(outcome):
            "capture:\(outcome.rawValue)"
        case let .providerHealth(health):
            "provider:\(health.rawValue)"
        case let .providerDiagnostic(providerClass, outcome, durationMilliseconds):
            "provider:\(providerClass.rawValue):\(outcome.rawValue):\(durationMilliseconds)"
        case let .translation(failure, durationMilliseconds):
            "translation:\(failure?.rawValue ?? "succeeded"):\(durationMilliseconds)"
        case let .history(outcome):
            "history:\(outcome.rawValue)"
        case let .permission(state):
            "permission:\(state.rawValue)"
        }
    }
}
