import AppKit
import Carbon.HIToolbox
import SharedSupport
import XCTest
@testable import SelectionCapture

final class GlobalShortcutTests: XCTestCase {
    private final class CapturedOwner: @unchecked Sendable {}

    private final class BoundaryOrderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] { lock.withLock { storage } }
        func record(_ value: String) { lock.withLock { storage.append(value) } }
    }

    private final class StubCarbonHotKeyClient: CarbonHotKeyClient, @unchecked Sendable {
        private let lock = NSLock()
        var registrationStatus: OSStatus
        var unregistrationStatus: OSStatus = noErr
        var handlerRemovalStatus: OSStatus = noErr
        private(set) var lastKeyCode: UInt32?
        private(set) var lastModifiers: UInt32?
        private(set) var lastOptions: UInt32?
        private(set) var handlerInstallCount = 0
        private(set) var handlerRemoveCount = 0
        private(set) var unregisterCount = 0
        private var callbackBox: CarbonCallbackBox?
        var blockHandlerInstall = false
        let handlerInstallEntered = DispatchSemaphore(value: 0)
        let releaseHandlerInstall = DispatchSemaphore(value: 0)

        init(status: OSStatus) { registrationStatus = status }

        func installHandler(
            _ emit: @escaping @Sendable () -> Void
        ) -> (OSStatus, CarbonEventHandlerToken?) {
            let box = CarbonCallbackBox(emit: emit)
            lock.withLock {
                handlerInstallCount += 1
                callbackBox = box
            }
            if blockHandlerInstall {
                handlerInstallEntered.signal()
                releaseHandlerInstall.wait()
            }
            return (noErr, .fixture(callbackBox: box))
        }

        func removeHandler(_ token: CarbonEventHandlerToken) -> OSStatus {
            lock.withLock {
                handlerRemoveCount += 1
                return handlerRemovalStatus
            }
        }

        func register(
            keyCode: UInt32,
            modifiers: UInt32,
            options: UInt32
        ) -> (OSStatus, CarbonHotKeyToken?) {
            lock.withLock {
                lastKeyCode = keyCode
                lastModifiers = modifiers
                lastOptions = options
            }
            return registrationStatus == noErr
                ? (noErr, CarbonHotKeyToken.fixture())
                : (registrationStatus, nil)
        }

        func unregister(_ token: CarbonHotKeyToken) -> OSStatus {
            lock.withLock {
                unregisterCount += 1
                return unregistrationStatus
            }
        }

        var snapshot: (UInt32?, UInt32?, UInt32?, Int, Int, Int) {
            lock.withLock {
                (
                    lastKeyCode,
                    lastModifiers,
                    lastOptions,
                    handlerInstallCount,
                    handlerRemoveCount,
                    unregisterCount
                )
            }
        }

        func invokeCallback() {
            let box = lock.withLock { callbackBox }
            box?.invokeIfActive()
        }
    }

    func testDefaultShortcutRegistersOptionShiftD() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        try await registrar.register(.defaultOptionShiftD)
        let values = carbon.snapshot
        XCTAssertEqual(values.0, UInt32(kVK_ANSI_D))
        XCTAssertEqual(values.1, UInt32(optionKey | shiftKey))
        XCTAssertEqual(
            values.2,
            UInt32(kEventHotKeyExclusive)
        )
    }

    func testMatchedCarbonCallbackReportsBoundaryBeforeEmission() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let order = BoundaryOrderSpy()
        let registrar = GlobalShortcutRegistrar(
            client: carbon,
            emit: { order.record("emit") },
            onShortcutReceived: { order.record("received") }
        )
        try await registrar.register(.defaultOptionShiftD)

        carbon.invokeCallback()

        XCTAssertEqual(order.values, ["received", "emit"])
    }

    func testRecordedModifiersConvertWithoutChangingDescriptor() throws {
        let descriptor = ShortcutDescriptor(
            keyCode: 2,
            modifiers: UInt32(
                NSEvent.ModifierFlags([.option, .shift]).rawValue
            )
        )
        XCTAssertEqual(
            try CarbonModifierConverter.convert(descriptor.modifiers),
            UInt32(optionKey | shiftKey)
        )
        XCTAssertEqual(descriptor, .defaultOptionShiftD)
        XCTAssertThrowsError(
            try CarbonModifierConverter.convert(
                descriptor.modifiers | UInt32(NSEvent.ModifierFlags.capsLock.rawValue)
            )
        )
    }

    func testConflictIsReportedWithoutFallbackMonitor() async {
        let carbon = StubCarbonHotKeyClient(
            status: OSStatus(eventHotKeyExistsErr)
        )
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        do {
            try await registrar.register(.defaultOptionShiftD)
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? ShortcutRegistrationFailure, .conflict)
        }
        let values = carbon.snapshot
        XCTAssertEqual(values.3, 1)
        XCTAssertEqual(values.4, 1)
        XCTAssertEqual(values.5, 0)
    }

    func testReregisterAndUnregisterReleaseEachOwnedReferenceOnce() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        try await registrar.register(.defaultOptionShiftD)
        try await registrar.register(.defaultOptionShiftD)
        XCTAssertEqual(carbon.snapshot.5, 1)
        await registrar.unregister()
        await registrar.unregister()
        XCTAssertEqual(carbon.snapshot.5, 2)
        XCTAssertEqual(carbon.snapshot.4, 2)
        XCTAssertEqual(carbon.snapshot.3, 2)
    }

    func testFailedHotKeyUnregistrationRetainsReferenceForRetry() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        try await registrar.register(.defaultOptionShiftD)
        carbon.unregistrationStatus = OSStatus(eventInternalErr)
        await registrar.unregister()
        carbon.unregistrationStatus = noErr
        await registrar.unregister()
        XCTAssertEqual(carbon.snapshot.5, 2)
        XCTAssertEqual(carbon.snapshot.4, 1)
    }

    func testFailedHandlerRemovalRetainsHandlerForRetry() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        try await registrar.register(.defaultOptionShiftD)
        carbon.handlerRemovalStatus = OSStatus(eventInternalErr)
        await registrar.unregister()
        carbon.handlerRemovalStatus = noErr
        await registrar.unregister()
        XCTAssertEqual(carbon.snapshot.5, 1)
        XCTAssertEqual(carbon.snapshot.4, 2)
        XCTAssertEqual(carbon.snapshot.3, 1)
    }

    func testFailedReregisterRetainsOldHotKeyAndDoesNotRegisterReplacement() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        try await registrar.register(.defaultOptionShiftD)
        carbon.unregistrationStatus = OSStatus(eventInternalErr)
        do {
            try await registrar.register(.defaultOptionShiftD)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ShortcutRegistrationFailure, .unavailable)
        }
        XCTAssertEqual(carbon.snapshot.5, 1)
        XCTAssertEqual(carbon.snapshot.3, 1)
    }

    func testDeactivatedCallbackEmitsNothingAndReleasesCapturedOwner() {
        var owner: CapturedOwner? = CapturedOwner()
        weak let weakOwner = owner
        let count = LockedCounter()
        let box = CarbonCallbackBox { [captured = owner] in
            withExtendedLifetime(captured) { count.increment() }
        }
        box.invokeIfActive()
        XCTAssertEqual(count.value, 1)
        owner = nil
        XCTAssertNotNil(weakOwner)
        box.deactivate()
        XCTAssertNil(weakOwner)
        box.invokeIfActive()
        XCTAssertEqual(count.value, 1)
    }

    func testFailedUnregisterMakesRetainedCallbackInert() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        let count = LockedCounter()
        let registrar = GlobalShortcutRegistrar(
            client: carbon,
            emit: count.increment
        )
        try await registrar.register(.defaultOptionShiftD)
        carbon.unregistrationStatus = OSStatus(eventInternalErr)
        await registrar.unregister()
        carbon.invokeCallback()
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(carbon.snapshot.5, 1)

        carbon.unregistrationStatus = noErr
        await registrar.unregister()
        XCTAssertEqual(carbon.snapshot.5, 2)
    }

    func testConcurrentUnregisterWaitsForRegistrationTransaction() async throws {
        let carbon = StubCarbonHotKeyClient(status: noErr)
        carbon.blockHandlerInstall = true
        let registrar = GlobalShortcutRegistrar(client: carbon, emit: {})
        let registration = Task {
            try await registrar.register(.defaultOptionShiftD)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                carbon.handlerInstallEntered.wait()
                continuation.resume()
            }
        }
        let unregistration = Task { await registrar.unregister() }
        for _ in 0..<20 { await Task.yield() }
        carbon.releaseHandlerInstall.signal()
        try await registration.value
        await unregistration.value
        XCTAssertEqual(carbon.snapshot.5, 1)
        XCTAssertEqual(carbon.snapshot.4, 1)
    }
}
