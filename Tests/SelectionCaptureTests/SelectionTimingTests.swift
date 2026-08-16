import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class SelectionTimingTests: XCTestCase {
    func testMouseEmitsAt350Milliseconds() async {
        let clock = ManualAppClock()
        let spy = AsyncTriggerSpy()
        let debouncer = SelectionDebouncer(delay: .milliseconds(350), clock: clock)
        await debouncer.submit(.mouse, emit: spy.record)
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(349))
        XCTAssertEqual(spy.values, [])
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(spy.values, [.mouse])
    }

    func testNewMouseEventReplacesPendingEvent() async {
        let clock = ManualAppClock()
        let spy = AsyncTriggerSpy()
        let debouncer = SelectionDebouncer(delay: .milliseconds(350), clock: clock)
        await debouncer.submit(.mouse, emit: spy.record)
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(200))
        await debouncer.submit(.mouse, emit: spy.record)
        await clock.waitForSleepers(2)
        await clock.advance(by: .milliseconds(150))
        XCTAssertEqual(spy.values, [])
        await clock.advance(by: .milliseconds(199))
        XCTAssertEqual(spy.values, [])
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(spy.values, [.mouse])
    }

    func testDuplicateKeyIsTrimmedTextPlusApplication() throws {
        var suppressor = DuplicateSuppressor()
        let appA = ApplicationIdentity(
            bundleIdentifier: "invalid.example.a",
            displayName: "Fixture A"
        )
        let appB = ApplicationIdentity(
            bundleIdentifier: "invalid.example.b",
            displayName: "Fixture B"
        )
        let first = try XCTUnwrap(suppressor.reserveIfNew(
            text: "hello", application: appA
        ))
        suppressor.commit(first)
        XCTAssertNil(suppressor.reserveIfNew(text: "hello", application: appA))
        XCTAssertNotNil(suppressor.reserveIfNew(text: "hello", application: appB))
        XCTAssertNotNil(suppressor.reserveIfNew(text: "world", application: appA))
        suppressor.reset()
        XCTAssertNotNil(suppressor.reserveIfNew(text: "hello", application: appA))
    }
}

private final class AsyncTriggerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CaptureTrigger] = []
    var values: [CaptureTrigger] { lock.withLock { storage } }
    func record(_ trigger: CaptureTrigger) async {
        lock.withLock { storage.append(trigger) }
    }
}
