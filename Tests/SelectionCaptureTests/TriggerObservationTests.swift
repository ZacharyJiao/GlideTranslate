import AppKit
import SharedSupport
import XCTest
@testable import SelectionCapture

final class TriggerObservationTests: XCTestCase {
    private final class TriggerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CaptureTrigger] = []
        var values: [CaptureTrigger] { lock.withLock { storage } }
        func record(_ trigger: CaptureTrigger) { lock.withLock { storage.append(trigger) } }
    }

    private final class BoundaryOrderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] { lock.withLock { storage } }
        func record(_ value: String) { lock.withLock { storage.append(value) } }
    }

    private final class MonitorClientSpy: SelectionEventMonitorClient, @unchecked Sendable {
        private let lock = NSLock()
        private var nextID = 0
        private(set) var mouseInstalls = 0
        private(set) var keyboardInstalls = 0
        private(set) var removals = 0
        private var mouseHandler: (@Sendable () -> Void)?
        private var keyHandler:
            (@Sendable (UInt16, NSEvent.ModifierFlags) -> Void)?
        var failKeyboardInstall = false
        var blockMouseInstall = false
        let mouseInstallEntered = DispatchSemaphore(value: 0)
        let releaseMouseInstall = DispatchSemaphore(value: 0)

        func addMouseUpMonitor(
            _ handler: @escaping @Sendable () -> Void
        ) -> SelectionEventMonitorToken? {
            let token = lock.withLock {
                mouseInstalls += 1
                mouseHandler = handler
                nextID += 1
                return SelectionEventMonitorToken(id: nextID)
            }
            if blockMouseInstall {
                mouseInstallEntered.signal()
                releaseMouseInstall.wait()
            }
            return token
        }

        func addKeyDownMonitor(
            _ handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags) -> Void
        ) -> SelectionEventMonitorToken? {
            lock.withLock {
                keyboardInstalls += 1
                keyHandler = handler
                if failKeyboardInstall { return nil }
                nextID += 1
                return SelectionEventMonitorToken(id: nextID)
            }
        }

        func removeMonitor(_ token: SelectionEventMonitorToken) {
            lock.withLock { removals += 1 }
        }

        var counts: (Int, Int, Int) {
            lock.withLock { (mouseInstalls, keyboardInstalls, removals) }
        }

        func invokeMouse() {
            lock.withLock { mouseHandler }?()
        }

        func invokeKey(
            code: UInt16,
            flags: NSEvent.ModifierFlags
        ) {
            lock.withLock { keyHandler }?(code, flags)
        }
    }

    func testKnownSelectionExtensionKeysOnly() {
        let rows: [(UInt16, NSEvent.ModifierFlags, KnownSelectionKey?)] = [
            (123, [.shift], .shiftLeft),
            (124, [.shift], .shiftRight),
            (125, [.shift], .shiftDown),
            (126, [.shift], .shiftUp),
            (123, [.option, .shift], .optionShiftLeft),
            (124, [.option, .shift], .optionShiftRight),
            (123, [.command, .shift], .commandShiftLeft),
            (124, [.command, .shift], .commandShiftRight),
            (115, [.shift], .shiftHome),
            (119, [.shift], .shiftEnd),
            (0, [], nil),
            (0, [.shift], nil),
            (123, [], nil),
            (36, [.shift], nil),
            (123, [.control, .shift], nil)
        ]
        for row in rows {
            XCTAssertEqual(
                KnownSelectionKey.classify(keyCode: row.0, flags: row.1),
                row.2
            )
        }
    }

    func testMonitorEmitsOnlyMouseUpAndKnownEnabledKey() async {
        let spy = TriggerSpy()
        let monitor = SelectionEventMonitor(emit: spy.record)
        await monitor.handle(.mouseUp, keyboardEnabled: true)
        await monitor.handle(
            .keyDown(code: 123, flags: [.shift]),
            keyboardEnabled: false
        )
        await monitor.handle(
            .keyDown(code: 123, flags: [.shift]),
            keyboardEnabled: true
        )
        await monitor.handle(
            .keyDown(code: 0, flags: [.shift]),
            keyboardEnabled: true
        )
        await monitor.handle(.programmaticSelectionChanged, keyboardEnabled: true)
        XCTAssertEqual(spy.values, [.mouse, .keyboardSelection])
    }

    func testGlobalCallbacksReportBoundaryBeforeTriggerEmission() async throws {
        let client = MonitorClientSpy()
        let order = BoundaryOrderSpy()
        let monitor = SelectionEventMonitor(
            client: client,
            emit: { trigger in
                order.record("emit.\(String(describing: trigger))")
            },
            onTriggerReceived: { trigger in
                order.record("received.\(String(describing: trigger))")
            }
        )
        try await monitor.start(mouseEnabled: true, keyboardEnabled: true)

        client.invokeMouse()
        client.invokeKey(code: 123, flags: [.shift])
        client.invokeKey(code: 0, flags: [.shift])

        XCTAssertEqual(order.values, [
            "received.mouse",
            "emit.mouse",
            "received.keyboardSelection",
            "emit.keyboardSelection"
        ])
    }

    func testStartUpdateStopOwnsOnlyEnabledMonitors() async throws {
        let client = MonitorClientSpy()
        let monitor = SelectionEventMonitor(client: client) { _ in }
        try await monitor.start(mouseEnabled: true, keyboardEnabled: false)
        try await monitor.start(mouseEnabled: true, keyboardEnabled: false)
        XCTAssertEqual(client.counts.0, 1)
        XCTAssertEqual(client.counts.1, 0)
        XCTAssertEqual(client.counts.2, 0)

        try await monitor.start(mouseEnabled: false, keyboardEnabled: true)
        XCTAssertEqual(client.counts.0, 1)
        XCTAssertEqual(client.counts.1, 1)
        XCTAssertEqual(client.counts.2, 1)
        await monitor.stop()
        await monitor.stop()
        XCTAssertEqual(client.counts.2, 2)
    }

    func testFailedUpdateDoesNotLeaveAStaleInstalledConfiguration() async throws {
        let client = MonitorClientSpy()
        let monitor = SelectionEventMonitor(client: client) { _ in }
        try await monitor.start(mouseEnabled: true, keyboardEnabled: false)
        client.failKeyboardInstall = true
        do {
            try await monitor.start(mouseEnabled: false, keyboardEnabled: true)
            XCTFail("expected unavailable monitor")
        } catch {
            XCTAssertEqual(error as? SelectionMonitorFailure, .unavailable)
        }
        client.failKeyboardInstall = false
        try await monitor.start(mouseEnabled: true, keyboardEnabled: false)
        XCTAssertEqual(client.counts.0, 2)
        XCTAssertEqual(client.counts.2, 1)
    }

    func testConcurrentStopWaitsForInFlightStartThenRemovesInstalledMonitor() async throws {
        let client = MonitorClientSpy()
        client.blockMouseInstall = true
        let monitor = SelectionEventMonitor(client: client) { _ in }
        let start = Task {
            try await monitor.start(mouseEnabled: true, keyboardEnabled: false)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                client.mouseInstallEntered.wait()
                continuation.resume()
            }
        }
        let stop = Task { await monitor.stop() }
        for _ in 0..<20 { await Task.yield() }
        client.releaseMouseInstall.signal()
        try await start.value
        await stop.value
        XCTAssertEqual(client.counts.0, 1)
        XCTAssertEqual(client.counts.2, 1)
    }
}
