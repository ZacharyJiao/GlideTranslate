import Foundation
import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class ChromiumPipelineCharacterizationTests: XCTestCase {
    private enum ConfigurationFailure: Error, Equatable {
        case markerMissing
        case markerUnsafe
        case pidMissing
        case pidInvalid
        case bundleInvalid
    }

    private struct RealCharacterizationConfiguration: Equatable {
        let marker: String
        let expectedPID: Int32
        let expectedBundleID: String

        static func resolve(
            environment: [String: String]
        ) -> Result<Self, ConfigurationFailure> {
            let optedIn = environment[
                "GLIDETRANSLATE_RUN_REAL_AX_CHARACTERIZATION"
            ] == "1"
                || environment[
                    "GLIDETRANSLATE_RUN_REAL_AX_PIPELINE_CHARACTERIZATION"
                ] == "1"
            guard optedIn else {
                return .failure(.markerMissing)
            }

            guard let marker = environment[
                "GLIDETRANSLATE_REAL_AX_EXPECTED_MARKER"
            ] else {
                return .failure(.markerMissing)
            }
            guard !marker.isEmpty,
                  marker.count <= 2_000,
                  marker.rangeOfCharacter(from: .newlines) == nil,
                  marker == marker.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ) else {
                return .failure(.markerUnsafe)
            }

            guard let pidText = environment["GLIDETRANSLATE_REAL_AX_PID"] else {
                return .failure(.pidMissing)
            }
            guard let expectedPID = Int32(pidText), expectedPID > 0 else {
                return .failure(.pidInvalid)
            }

            let expectedBundleID = environment[
                "GLIDETRANSLATE_REAL_AX_PIPELINE_BUNDLE_ID"
            ] ?? "com.google.Chrome"
            guard !expectedBundleID.isEmpty,
                  expectedBundleID.rangeOfCharacter(
                      from: .whitespacesAndNewlines
                  ) == nil,
                  expectedBundleID.split(separator: ".").count >= 2 else {
                return .failure(.bundleInvalid)
            }

            return .success(Self(
                marker: marker,
                expectedPID: expectedPID,
                expectedBundleID: expectedBundleID
            ))
        }
    }

    private struct ForegroundMetadata: Equatable, Sendable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let activationSequence: UInt64
    }

    private final class RecordingForegroundReader:
        ForegroundApplicationReading, @unchecked Sendable {
        private let base: any ForegroundApplicationReading
        private let lock = NSLock()
        private var samples: [ForegroundMetadata] = []

        init(base: any ForegroundApplicationReading) {
            self.base = base
        }

        var metadata: [ForegroundMetadata] {
            lock.withLock { samples }
        }

        func current() async
            -> Result<ForegroundApplicationContext, SelectionAuthorizationFailure> {
            let result = await base.current()
            if case .success(let context) = result {
                lock.withLock {
                    samples.append(ForegroundMetadata(
                        bundleIdentifier: context.application.bundleIdentifier,
                        processIdentifier: context.processIdentifier,
                        activationSequence: context.activationSequence
                    ))
                }
            }
            return result
        }
    }

    func testOptInConfigurationRejectsInvalidPIDWithoutEchoingMarker() {
        let result = RealCharacterizationConfiguration.resolve(environment: [
            "GLIDETRANSLATE_RUN_REAL_AX_PIPELINE_CHARACTERIZATION": "1",
            "GLIDETRANSLATE_REAL_AX_EXPECTED_MARKER": "synthetic-marker",
            "GLIDETRANSLATE_REAL_AX_PID": "invalid"
        ])

        guard case .failure(.pidInvalid) = result else {
            XCTFail("CONFIGURATION_ERROR: pid_invalid")
            return
        }
    }

    func testOptInRealChromeBodyTraversesFullAuthorizationPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let realAXOptIn = environment[
            "GLIDETRANSLATE_RUN_REAL_AX_CHARACTERIZATION"
        ] == "1"
            || environment[
                "GLIDETRANSLATE_RUN_REAL_AX_PIPELINE_CHARACTERIZATION"
            ] == "1"
        guard realAXOptIn else {
            // Configuration failures after opt-in are converted to XCTest
            // failures below; only the no-opt-in path is an intentional skip.
            throw XCTSkip(
                "PLANNED_SKIP: controller-owned real Chromium pipeline characterization"
            )
        }

        let configuration: RealCharacterizationConfiguration
        switch RealCharacterizationConfiguration.resolve(environment: environment) {
        case .success(let resolved):
            configuration = resolved
        case .failure(let failure):
            XCTFail(Self.configurationMessage(for: failure))
            return
        }

        let marker = configuration.marker
        let expectedPID = configuration.expectedPID
        let expectedBundleID = configuration.expectedBundleID

        let foreground = RecordingForegroundReader(
            base: DefaultForegroundApplicationReader()
        )
        guard case .success(let initialContext) = await foreground.current() else {
            XCTFail("CONFIGURATION_ERROR: foreground_unavailable")
            return
        }
        guard initialContext.processIdentifier > 0,
              !initialContext.application.bundleIdentifier.isEmpty else {
            XCTFail("CONFIGURATION_ERROR: foreground_metadata_invalid")
            return
        }
        guard initialContext.application.bundleIdentifier == expectedBundleID else {
            XCTFail("CONFIGURATION_ERROR: foreground_bundle_mismatch")
            return
        }
        guard initialContext.processIdentifier == expectedPID else {
            XCTFail("CONFIGURATION_ERROR: foreground_pid_mismatch")
            return
        }

        let expectedProvider = ProviderDestinationSnapshot.fixture()
        let options = TranslationOptionsSnapshot.fixture()
        let policy = CapturePolicySnapshot(
            automaticCaptureEnabled: true,
            mouseSelectionEnabled: true,
            keyboardSelectionEnabled: false,
            generalAllowlist: [initialContext.application],
            offDeviceAllowlist: [initialContext.application],
            clipboardFallbackEnabled: false,
            selectionDebounceMilliseconds: 0,
            selectionCharacterLimit: 2_000
        )
        let snapshot = StubSnapshotReader(expectedProvider)
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: foreground,
            systemReader: AccessibilitySelectionReader(),
            clipboardReader: StubClipboardReader(
                result: .failure(.noValidSelection)
            ),
            snapshotReader: snapshot,
            selectionFilter: SelectionFilter(limit: 2_000),
            duplicateChecker: DuplicateSuppressor()
        )
        let pipeline = SystemSelectionPipeline(
            foregroundReader: foreground,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .zero,
                clock: ManualAppClock()
            )
        )

        let shortcut = await pipeline.process(
            trigger: .shortcut,
            options: options,
            policy: policy,
            provider: expectedProvider
        )
        let automatic = await pipeline.process(
            trigger: .mouse,
            options: options,
            policy: policy,
            provider: expectedProvider
        )

        guard shortcut.isAuthorized else {
            XCTFail("OBSERVATION_MISMATCH: shortcut_not_authorized")
            return
        }
        guard hasAuthorizedMarker(shortcut, marker: marker) else {
            XCTFail("OBSERVATION_MISMATCH: shortcut_marker_mismatch")
            return
        }
        guard automatic.isAuthorized else {
            XCTFail("OBSERVATION_MISMATCH: automatic_not_authorized")
            return
        }
        guard hasAuthorizedMarker(automatic, marker: marker) else {
            XCTFail("OBSERVATION_MISMATCH: automatic_marker_mismatch")
            return
        }
        XCTAssertEqual(snapshot.count.value, 2)

        let metadata = foreground.metadata
        let bundleIDs = Set(metadata.map(\.bundleIdentifier))
        let processIDs = Set(metadata.map(\.processIdentifier))
        let activationChanged = zip(metadata, metadata.dropFirst()).contains {
            $0.activationSequence != $1.activationSequence
        }
        let processIDText = processIDs.sorted().map(String.init).joined(separator: ",")
        let activationSequenceText = metadata
            .map(\.activationSequence)
            .map(String.init)
            .joined(separator: ",")
        let shortcutCategory = category(shortcut)
        let automaticCategory = category(automatic)
        await MainActor.run {
            XCTContext.runActivity(named: "safe Chromium pipeline metadata") { _ in
                XCTContext.runActivity(
                    named: "bundleIDs=\(bundleIDs.sorted().joined(separator: ",")) "
                        + "sampleCount=\(metadata.count) "
                        + "pids=\(processIDText) "
                        + "activationSequences=\(activationSequenceText) "
                        + "activationChanged=\(activationChanged)"
                ) { _ in }
                XCTContext.runActivity(
                    named: "outcomes shortcut=\(shortcutCategory) automatic=\(automaticCategory)"
                ) { _ in }
            }
        }
    }

    private static func configurationMessage(
        for failure: ConfigurationFailure
    ) -> String {
        switch failure {
        case .markerMissing:
            "CONFIGURATION_ERROR: marker_missing"
        case .markerUnsafe:
            "CONFIGURATION_ERROR: marker_unsafe"
        case .pidMissing:
            "CONFIGURATION_ERROR: pid_missing"
        case .pidInvalid:
            "CONFIGURATION_ERROR: pid_invalid"
        case .bundleInvalid:
            "CONFIGURATION_ERROR: bundle_invalid"
        }
    }

    private func hasAuthorizedMarker(
        _ outcome: SelectionAuthorizationOutcome,
        marker: String
    ) -> Bool {
        guard case .authorized(_, let presentation) = outcome else {
            return false
        }
        return presentation.sourceText == marker
    }

    private func category(_ outcome: SelectionAuthorizationOutcome) -> String {
        switch outcome {
        case .authorized:
            return "authorized"
        case .manualInputRequired:
            return "manualInputRequired"
        case .rejected(let failure):
            return "rejected.\(String(describing: failure))"
        }
    }
}
