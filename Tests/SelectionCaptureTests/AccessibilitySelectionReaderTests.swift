import CoreGraphics
import Foundation
import SharedSupport
import XCTest
@testable import SelectionCapture

final class AccessibilitySelectionReaderTests: XCTestCase {
    private final class DiagnosticRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SelectionAXDiagnostic] = []

        var events: [SelectionAXDiagnostic] {
            lock.withLock { storage }
        }

        func record(_ event: SelectionAXDiagnostic) {
            lock.withLock { storage.append(event) }
        }
    }

    private enum StubResult {
        case success(AXSelectionMaterial)
        case failure(AXReadFailure)
    }

    private final class StubAXClient: AXSelectionClient, @unchecked Sendable {
        private let lock = NSLock()
        private let result: StubResult
        private var mainThreadCall = false

        init(_ result: StubResult) { self.result = result }

        var calledOnMainThread: Bool { lock.withLock { mainThreadCall } }

        func readSelection(pid: pid_t) throws -> AXSelectionMaterial {
            lock.withLock { mainThreadCall = Thread.isMainThread }
            switch result {
            case .success(let material): return material
            case .failure(let failure): throw failure
            }
        }
    }

    private final class StubAXSystem: AXSystemAccessing, @unchecked Sendable {
        enum FailurePoint {
            case none
            case applicationTimeout(AXOperationFailure)
            case manualAccessibilityUnavailable
            case focusedTimeout(AXOperationFailure)
            case text(AXOperationFailure)
            case textMarker(AXOperationFailure)
            case textAndMarkerUnavailable
            case bounds(AXOperationFailure)
            case focusedWithSystemWideFallback
            case focusedWithSelectionFallback
            case focusedWithoutSelectionWithDescendantFallback
            case focusedWithoutSelectionWithChildCannotCompleteThenExhausted
            case focusedWithoutSelectionWithApplicationWindowsCannotComplete
            case focusedTraversalExhausted
            case focusedTraversalCannotComplete
        }

        private let lock = NSLock()
        private let applicationObject = NSObject()
        private let focusedObject = NSObject()
        private let descendantSelectionObject = NSObject()
        private let failure: FailurePoint
        private let bounds: CGRect?
        private let selectedText: String
        private let traversalDiagnosticHandler: SelectionAXDiagnosticHandler?
        private var eventStorage: [String] = []

        init(
            failure: FailurePoint = .none,
            bounds: CGRect? = nil,
            selectedText: String = "synthetic text",
            traversalDiagnosticHandler: SelectionAXDiagnosticHandler? = nil
        ) {
            self.failure = failure
            self.bounds = bounds
            self.selectedText = selectedText
            self.traversalDiagnosticHandler = traversalDiagnosticHandler
        }

        var events: [String] { lock.withLock { eventStorage } }
        private func record(_ value: String) { lock.withLock { eventStorage.append(value) } }

        func isTrusted() -> Bool { record("trusted"); return true }

        func makeApplication(pid: pid_t) -> AXElementToken {
            record("make application")
            return AXElementToken(raw: applicationObject)
        }

        func setMessagingTimeout(
            _ seconds: Float,
            for element: AXElementToken
        ) throws {
            if element.identifier == ObjectIdentifier(applicationObject) {
                record("timeout application")
                if case .applicationTimeout(let failure) = failure { throw failure }
            } else {
                record("timeout focused")
                if case .focusedTimeout(let failure) = failure { throw failure }
            }
        }

        func focusedElement(of application: AXElementToken) throws -> AXElementToken {
            record("focused element")
            if case .focusedWithSystemWideFallback = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithSelectionFallback = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedTraversalExhausted = failure,
               application.identifier == ObjectIdentifier(applicationObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedTraversalCannotComplete = failure,
               application.identifier == ObjectIdentifier(applicationObject) {
                throw AXOperationFailure.unavailable
            }
            return AXElementToken(raw: focusedObject)
        }

        func enableManualAccessibility(of application: AXElementToken) throws {
            record("enable manual accessibility")
            if case .manualAccessibilityUnavailable = failure {
                throw AXOperationFailure.unavailable
            }
        }

        func systemWideFocusedElement(expectedPID: pid_t) throws -> AXElementToken {
            record("system wide focused element")
            if case .focusedWithSelectionFallback = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedTraversalExhausted = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedTraversalCannotComplete = failure {
                throw AXOperationFailure.unavailable
            }
            return AXElementToken(raw: focusedObject)
        }

        func selectionElementFallback(
            of application: AXElementToken
        ) throws -> AXElementToken {
            record("selection element fallback")
            if case .focusedWithoutSelectionWithDescendantFallback = failure {
                return AXElementToken(raw: descendantSelectionObject)
            }
            if case .focusedWithoutSelectionWithChildCannotCompleteThenExhausted = failure {
                traversalDiagnosticHandler?(.descendantTraversalCannotComplete)
                throw AXOperationFailure.traversalExhausted
            }
            if case .focusedWithoutSelectionWithApplicationWindowsCannotComplete = failure {
                traversalDiagnosticHandler?(.descendantTraversalCannotComplete)
                throw AXOperationFailure.traversalCannotComplete
            }
            if case .focusedTraversalExhausted = failure {
                throw AXOperationFailure.traversalExhausted
            }
            if case .focusedTraversalCannotComplete = failure {
                throw AXOperationFailure.traversalCannotComplete
            }
            return AXElementToken(raw: focusedObject)
        }

        func selectedText(of element: AXElementToken) throws -> String {
            record("selected text")
            if case .text(let failure) = failure { throw failure }
            if case .textAndMarkerUnavailable = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithDescendantFallback = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithChildCannotCompleteThenExhausted = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithApplicationWindowsCannotComplete = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            return selectedText
        }

        func selectedTextFromTextMarkerRange(
            of element: AXElementToken
        ) throws -> String {
            record("selected text marker range")
            if case .textMarker(let failure) = failure { throw failure }
            if case .textAndMarkerUnavailable = failure {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithDescendantFallback = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithChildCannotCompleteThenExhausted = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithApplicationWindowsCannotComplete = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            return "synthetic marker text"
        }

        func selectedTextFromValueRange(
            of element: AXElementToken
        ) throws -> String {
            record("selected text value range")
            if case .focusedWithoutSelectionWithDescendantFallback = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithChildCannotCompleteThenExhausted = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            if case .focusedWithoutSelectionWithApplicationWindowsCannotComplete = failure,
               element.identifier == ObjectIdentifier(focusedObject) {
                throw AXOperationFailure.unavailable
            }
            return "synthetic value range text"
        }

        func selectedBoundsTopLeftGlobal(
            of element: AXElementToken
        ) throws -> CGRect? {
            record("selected bounds")
            if case .bounds(let failure) = failure { throw failure }
            return bounds
        }
    }

    private final class BlockingAXClient: AXSelectionClient, @unchecked Sendable {
        let readCount = LockedCounter()
        let release = DispatchSemaphore(value: 0)

        func readSelection(pid: pid_t) throws -> AXSelectionMaterial {
            readCount.increment()
            release.wait()
            return AXSelectionMaterial(text: "synthetic", displayRect: nil)
        }
    }

    func testAccessibilityResultMatrix() async throws {
        let context = ForegroundApplicationContext(
            application: ApplicationIdentity(
                bundleIdentifier: "invalid.example.ax",
                displayName: "Fixture"
            ),
            processIdentifier: 42,
            activationSequence: 1
        )
        let rows: [(String, StubResult, Result<CapturedSelection, SelectionAuthorizationFailure>)] = [
            ("text and bounds",
             .success(AXSelectionMaterial(
                text: "  hello  ",
                displayRect: CGRect(x: 100, y: 200, width: 50, height: 20)
             )),
             .success(CapturedSelection(
                text: "  hello  ",
                displayRect: CGRect(x: 100, y: 200, width: 50, height: 20)
             ))),
            ("text without bounds",
             .success(AXSelectionMaterial(text: "hello", displayRect: nil)),
             .success(CapturedSelection(text: "hello", displayRect: nil))),
            ("not trusted", .failure(.notTrusted),
             .failure(.accessibilityPermissionMissing)),
            ("no focused element", .failure(.focusedElementUnavailable),
             .failure(.unsupportedApplication)),
            ("selected text unsupported", .failure(.attributeUnsupported),
             .failure(.unsupportedApplication)),
            ("cannot complete", .failure(.cannotComplete),
             .failure(.selectionReadTimedOut)),
            ("empty selected text", .failure(.emptyValue),
             .failure(.noValidSelection))
        ]

        for (name, result, expected) in rows {
            let client = StubAXClient(result)
            let reader = AccessibilitySelectionReader(client: client)
            let actual = await reader.read(context: context)
            XCTAssertEqual(actual, expected, name)
            XCTAssertFalse(client.calledOnMainThread, name)
        }
    }

    func testCoordinateMatrixAcrossDisplayArrangements() throws {
        let main = AXDisplaySnapshot(
            displayID: 1,
            quartzBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isMain: true,
            backingScaleFactor: 2
        )
        let left = AXDisplaySnapshot(
            displayID: 2,
            quartzBounds: CGRect(x: -1_280, y: 100, width: 1_280, height: 800),
            appKitFrame: CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
            isMain: false,
            backingScaleFactor: 1
        )
        let right = AXDisplaySnapshot(
            displayID: 3,
            quartzBounds: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            appKitFrame: CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080),
            isMain: false,
            backingScaleFactor: 2
        )
        let above = AXDisplaySnapshot(
            displayID: 4,
            quartzBounds: CGRect(x: 0, y: -768, width: 1_024, height: 768),
            appKitFrame: CGRect(x: 0, y: 900, width: 1_024, height: 768),
            isMain: false,
            backingScaleFactor: 2
        )
        let below = AXDisplaySnapshot(
            displayID: 5,
            quartzBounds: CGRect(x: 200, y: 900, width: 1_280, height: 720),
            appKitFrame: CGRect(x: 200, y: -720, width: 1_280, height: 720),
            isMain: false,
            backingScaleFactor: 1
        )
        let displays = [main, left, right, above, below]
        let rows: [(String, CGRect, CGRect, UInt32)] = [
            ("main retina logical points", CGRect(x: 100, y: 200, width: 50, height: 20),
             CGRect(x: 100, y: 680, width: 50, height: 20), 1),
            ("negative x left", CGRect(x: -1_200, y: 200, width: 40, height: 30),
             CGRect(x: -1_200, y: 670, width: 40, height: 30), 2),
            ("unequal taller right", CGRect(x: 1_500, y: 100, width: 60, height: 40),
             CGRect(x: 1_500, y: 760, width: 60, height: 40), 3),
            ("negative ax y above", CGRect(x: 100, y: -700, width: 30, height: 20),
             CGRect(x: 100, y: 1_580, width: 30, height: 20), 4),
            ("ax y beyond main below", CGRect(x: 300, y: 1_000, width: 80, height: 20),
             CGRect(x: 300, y: -120, width: 80, height: 20), 5)
        ]

        for (name, input, expected, displayID) in rows {
            let output = try XCTUnwrap(
                AXCoordinateConverter.appKitGlobalRect(input, displays: displays),
                name
            )
            XCTAssertEqual(output, expected, name)
            let display = try XCTUnwrap(displays.first { $0.displayID == displayID })
            XCTAssertTrue(display.appKitFrame.contains(output.center), name)
        }
    }

    func testInvalidCoordinateSnapshotsReturnNil() {
        let main = AXDisplaySnapshot(
            displayID: 1,
            quartzBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isMain: true,
            backingScaleFactor: 2
        )
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertNil(AXCoordinateConverter.appKitGlobalRect(
            rect,
            displays: [main, AXDisplaySnapshot(
                displayID: 2,
                quartzBounds: CGRect(x: 1_440, y: 0, width: 900, height: 700),
                appKitFrame: CGRect(x: 1_440, y: 0, width: 800, height: 700),
                isMain: false,
                backingScaleFactor: 1
            )]
        ))
        XCTAssertNil(AXCoordinateConverter.appKitGlobalRect(
            CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10),
            displays: [main]
        ))
        XCTAssertNil(AXCoordinateConverter.appKitGlobalRect(rect, displays: []))
        XCTAssertNil(AXCoordinateConverter.appKitGlobalRect(
            CGRect(x: 5_000, y: 5_000, width: 10, height: 10),
            displays: [main]
        ))
    }

    func testSystemClientInstallsTimeoutOnApplicationAndFocusedElement() throws {
        let system = StubAXSystem()
        let material = try SystemAXClient(system: system).readSelection(pid: 42)
        XCTAssertEqual(material, AXSelectionMaterial(
            text: "synthetic text",
            displayRect: nil
        ))
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused", "selected text",
            "selected bounds"
        ])
    }

    func testUnsupportedManualAccessibilityDoesNotBlockNativeSelectionRead() throws {
        let system = StubAXSystem(failure: .manualAccessibilityUnavailable)

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused",
            "selected text", "selected bounds",
        ])
    }

    func testSystemClientFallsBackToWebTextMarkerRangeWhenSelectedTextIsUnsupported() throws {
        let system = StubAXSystem(failure: .text(.unavailable))

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material, AXSelectionMaterial(
            text: "synthetic marker text",
            displayRect: nil
        ))
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused", "selected text",
            "selected text marker range", "selected bounds",
        ])
    }

    func testSystemClientFallsBackToTextMarkerRangeWhenSelectedTextIsEmpty() throws {
        let system = StubAXSystem(selectedText: "")

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic marker text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused", "selected text",
            "selected text marker range", "selected bounds",
        ])
    }

    func testSystemClientFallsBackToSelectedDescendantWhenFocusedElementIsUnavailable() throws {
        let system = StubAXSystem(failure: .focusedWithSelectionFallback)

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "system wide focused element",
            "selection element fallback", "timeout focused",
            "selected text", "selected bounds",
        ])
    }

    func testSystemClientUsesSameProcessSystemWideFocusBeforeTreeSearch() throws {
        let system = StubAXSystem(failure: .focusedWithSystemWideFallback)

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "system wide focused element", "timeout focused",
            "selected text", "selected bounds",
        ])
    }

    func testSystemClientTraversesSelectionTreeWhenFocusedElementHasNoSelectionAttributes() throws {
        let system = StubAXSystem(
            failure: .focusedWithoutSelectionWithDescendantFallback
        )

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused",
            "selected text", "selected text marker range", "selected text value range",
            "selection element fallback", "timeout focused", "selected text", "selected bounds",
        ])
    }

    func testSystemClientReportsClosedAXStageDiagnostics() throws {
        let focusedFallbackRecorder = DiagnosticRecorder()
        let focusedFallbackSystem = StubAXSystem(
            failure: .focusedWithSelectionFallback
        )
        _ = try SystemAXClient(
            system: focusedFallbackSystem,
            diagnosticHandler: focusedFallbackRecorder.record
        ).readSelection(pid: 42)
        XCTAssertEqual(focusedFallbackRecorder.events, [
            .focusedLookupApplicationUnsupported,
            .focusedLookupSystemWideUnsupported,
            .focusedLookupDescendantSucceeded,
            .descendantTraversalSucceeded,
            .directSelectionSucceeded,
        ])

        let markerRecorder = DiagnosticRecorder()
        let markerSystem = StubAXSystem(failure: .text(.unavailable))
        _ = try SystemAXClient(
            system: markerSystem,
            diagnosticHandler: markerRecorder.record
        ).readSelection(pid: 42)
        XCTAssertEqual(markerRecorder.events, [
            .focusedLookupApplicationSucceeded,
            .directSelectionUnsupported,
            .markerSelectionSucceeded,
        ])

        let emptyRecorder = DiagnosticRecorder()
        let emptySystem = StubAXSystem(selectedText: "")
        _ = try SystemAXClient(
            system: emptySystem,
            diagnosticHandler: emptyRecorder.record
        ).readSelection(pid: 42)
        XCTAssertEqual(emptyRecorder.events, [
            .focusedLookupApplicationSucceeded,
            .directSelectionEmpty,
            .markerSelectionSucceeded,
        ])

        let cannotCompleteRecorder = DiagnosticRecorder()
        let cannotCompleteSystem = StubAXSystem(
            failure: .textMarker(.cannotComplete),
            selectedText: ""
        )
        XCTAssertThrowsError(
            try SystemAXClient(
                system: cannotCompleteSystem,
                diagnosticHandler: cannotCompleteRecorder.record
            ).readSelection(pid: 42)
        )
        XCTAssertEqual(cannotCompleteRecorder.events, [
            .focusedLookupApplicationSucceeded,
            .directSelectionEmpty,
            .markerSelectionCannotComplete,
        ])

        for (failure, expected) in [
            (
                StubAXSystem.FailurePoint.focusedTraversalExhausted,
                [
                    SelectionAXDiagnostic.focusedLookupApplicationUnsupported,
                    .focusedLookupSystemWideUnsupported,
                    .focusedLookupDescendantUnsupported,
                    .descendantTraversalExhausted,
                ]
            ),
            (
                StubAXSystem.FailurePoint.focusedTraversalCannotComplete,
                [
                    SelectionAXDiagnostic.focusedLookupApplicationUnsupported,
                    .focusedLookupSystemWideUnsupported,
                    .focusedLookupDescendantCannotComplete,
                    .descendantTraversalCannotComplete,
                ]
            ),
        ] as [(StubAXSystem.FailurePoint, [SelectionAXDiagnostic])] {
            let recorder = DiagnosticRecorder()
            let system = StubAXSystem(failure: failure)
            XCTAssertThrowsError(
                try SystemAXClient(
                    system: system,
                    diagnosticHandler: recorder.record
                ).readSelection(pid: 42)
            )
            XCTAssertEqual(recorder.events, expected)
        }
    }

    func testChildTraversalCannotCompleteThenExhaustionPreservesUnsupportedOutcome() async throws {
        let recorder = DiagnosticRecorder()
        let system = StubAXSystem(
            failure: .focusedWithoutSelectionWithChildCannotCompleteThenExhausted,
            traversalDiagnosticHandler: recorder.record
        )
        let context = ForegroundApplicationContext(
            application: ApplicationIdentity(
                bundleIdentifier: "invalid.example.ax",
                displayName: "Fixture"
            ),
            processIdentifier: 42,
            activationSequence: 1
        )

        let actual = await AccessibilitySelectionReader(
            client: SystemAXClient(
                system: system,
                diagnosticHandler: recorder.record
            )
        ).read(context: context)

        XCTAssertEqual(actual, .failure(.unsupportedApplication))
        XCTAssertEqual(recorder.events, [
            .focusedLookupApplicationSucceeded,
            .directSelectionUnsupported,
            .markerSelectionUnsupported,
            .valueSelectionUnsupported,
            .descendantTraversalCannotComplete,
            .focusedLookupDescendantUnsupported,
            .descendantTraversalExhausted,
        ])
    }

    func testApplicationWindowsCannotCompletePreservesTimeoutOutcome() async throws {
        let recorder = DiagnosticRecorder()
        let system = StubAXSystem(
            failure: .focusedWithoutSelectionWithApplicationWindowsCannotComplete,
            traversalDiagnosticHandler: recorder.record
        )
        let context = ForegroundApplicationContext(
            application: ApplicationIdentity(
                bundleIdentifier: "invalid.example.ax",
                displayName: "Fixture"
            ),
            processIdentifier: 42,
            activationSequence: 1
        )

        let actual = await AccessibilitySelectionReader(
            client: SystemAXClient(
                system: system,
                diagnosticHandler: recorder.record
            )
        ).read(context: context)

        XCTAssertEqual(actual, .failure(.selectionReadTimedOut))
        XCTAssertEqual(recorder.events, [
            .focusedLookupApplicationSucceeded,
            .directSelectionUnsupported,
            .markerSelectionUnsupported,
            .valueSelectionUnsupported,
            .descendantTraversalCannotComplete,
            .focusedLookupDescendantCannotComplete,
            .descendantTraversalCannotComplete,
        ])
    }

    func testSystemClientFallsBackToValueRangeAfterDirectAndMarkerReadsAreUnavailable() throws {
        let system = StubAXSystem(failure: .textAndMarkerUnavailable)

        let material = try SystemAXClient(system: system).readSelection(pid: 42)

        XCTAssertEqual(material.text, "synthetic value range text")
        XCTAssertEqual(system.events, [
            "trusted", "make application", "timeout application",
            "enable manual accessibility", "focused element", "timeout focused", "selected text",
            "selected text marker range", "selected text value range",
            "selected bounds",
        ])
    }

    func testRealSystemCharacterizationReadsControllerPreparedWebSelection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GLIDETRANSLATE_RUN_REAL_AX_CHARACTERIZATION"] == "1" else {
            throw XCTSkip("PLANNED_SKIP: controller-owned real Accessibility characterization")
        }
        let expected = try XCTUnwrap(
            environment["GLIDETRANSLATE_REAL_AX_EXPECTED_MARKER"]
        )
        let pidText = try XCTUnwrap(environment["GLIDETRANSLATE_REAL_AX_PID"])
        let pid = try XCTUnwrap(pid_t(pidText))
        XCTAssertFalse(expected.isEmpty)
        XCTAssertLessThanOrEqual(expected.count, 2_000)

        let material = try SystemAXClient().readSelection(pid: pid)

        XCTAssertEqual(material.text, expected, "real AX selection must match the synthetic marker")
    }

    func testSystemClientMapsPermissionLossDuringMessaging() {
        for failure in [
            StubAXSystem.FailurePoint.applicationTimeout(.apiDisabled),
            .focusedTimeout(.apiDisabled),
            .text(.apiDisabled),
            .bounds(.apiDisabled)
        ] {
            let system = StubAXSystem(failure: failure)
            XCTAssertThrowsError(
                try SystemAXClient(system: system).readSelection(pid: 42)
            ) { error in
                XCTAssertEqual(error as? AXReadFailure, .notTrusted)
            }
        }
    }

    func testBoundsUnsupportedAndNonfiniteRemainTextOnly() throws {
        let unsupported = StubAXSystem(failure: .bounds(.unavailable))
        XCTAssertEqual(
            try SystemAXClient(system: unsupported).readSelection(pid: 42),
            AXSelectionMaterial(text: "synthetic text", displayRect: nil)
        )
        let nonfinite = StubAXSystem(bounds: CGRect(
            x: CGFloat.infinity,
            y: 0,
            width: 10,
            height: 10
        ))
        XCTAssertEqual(
            try SystemAXClient(system: nonfinite).readSelection(pid: 42),
            AXSelectionMaterial(text: "synthetic text", displayRect: nil)
        )
    }

    func testCancelledQueuedReadNeverCallsAXClient() async {
        let client = BlockingAXClient()
        let lane = AXExecutionLane()
        let context = ForegroundApplicationContext(
            application: ApplicationIdentity(
                bundleIdentifier: "invalid.example.ax",
                displayName: "Fixture"
            ),
            processIdentifier: 42,
            activationSequence: 1
        )
        let reader = AccessibilitySelectionReader(client: client, lane: lane)
        let first = Task { await reader.read(context: context) }
        while client.readCount.value == 0 { await Task.yield() }
        let second = Task { await reader.read(context: context) }
        for _ in 0..<20 { await Task.yield() }
        second.cancel()
        client.release.signal()

        guard case .success = await first.value else {
            return XCTFail("first queued read should succeed")
        }
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .failure(.cancelled))
        XCTAssertEqual(client.readCount.value, 1)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
