import CoreGraphics
import Foundation
import SharedSupport
import XCTest
@testable import SelectionCapture

final class AccessibilitySelectionReaderTests: XCTestCase {
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
            case focusedTimeout(AXOperationFailure)
            case text(AXOperationFailure)
            case bounds(AXOperationFailure)
        }

        private let lock = NSLock()
        private let applicationObject = NSObject()
        private let focusedObject = NSObject()
        private let failure: FailurePoint
        private let bounds: CGRect?
        private var eventStorage: [String] = []

        init(failure: FailurePoint = .none, bounds: CGRect? = nil) {
            self.failure = failure
            self.bounds = bounds
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
            return AXElementToken(raw: focusedObject)
        }

        func selectedText(of element: AXElementToken) throws -> String {
            record("selected text")
            if case .text(let failure) = failure { throw failure }
            return "synthetic text"
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
            "focused element", "timeout focused", "selected text",
            "selected bounds"
        ])
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
