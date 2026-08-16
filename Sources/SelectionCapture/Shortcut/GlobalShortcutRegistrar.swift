import AppKit
import Carbon.HIToolbox
import Foundation
import SharedSupport

private enum CarbonLifetimeQuarantine {
    private struct HandlerEntry {
        let reference: UInt
        let callbackBox: CarbonCallbackBox?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hotKeys: [UInt] = []
    nonisolated(unsafe) private static var handlers: [HandlerEntry] = []

    static func retainHotKey(_ reference: EventHotKeyRef) {
        lock.withLock { hotKeys.append(UInt(bitPattern: reference)) }
    }

    static func retainHandler(
        _ reference: EventHandlerRef,
        callbackBox: CarbonCallbackBox?
    ) {
        lock.withLock {
            handlers.append(HandlerEntry(
                reference: UInt(bitPattern: reference),
                callbackBox: callbackBox
            ))
        }
    }
}

public protocol GlobalShortcutRegistering: Sendable {
    func register(_ descriptor: ShortcutDescriptor) async throws
    func unregister() async
}

public enum ShortcutRegistrationFailure: Error, Equatable, Sendable {
    case conflict
    case unavailable
    case unsupportedModifiers
}

private final class CarbonHotKeyLifetime: @unchecked Sendable {
    private var reference: EventHotKeyRef?

    init(reference: EventHotKeyRef?) { self.reference = reference }

    func remove() -> OSStatus {
        guard let reference else { return noErr }
        let status = UnregisterEventHotKey(reference)
        if status == noErr { self.reference = nil }
        return status
    }

    deinit {
        guard let reference else { return }
        let raw = UInt(bitPattern: reference)
        if Thread.isMainThread {
            if UnregisterEventHotKey(reference) != noErr {
                CarbonLifetimeQuarantine.retainHotKey(reference)
            }
        } else {
            DispatchQueue.main.async {
                guard let reference = EventHotKeyRef(bitPattern: raw) else { return }
                if UnregisterEventHotKey(reference) != noErr {
                    CarbonLifetimeQuarantine.retainHotKey(reference)
                }
            }
        }
    }
}

private final class CarbonEventHandlerLifetime: @unchecked Sendable {
    private var reference: EventHandlerRef?
    private var callbackBox: CarbonCallbackBox?

    init(reference: EventHandlerRef?, callbackBox: CarbonCallbackBox) {
        self.reference = reference
        self.callbackBox = callbackBox
    }

    func remove() -> OSStatus {
        guard let reference else { return noErr }
        let status = RemoveEventHandler(reference)
        if status == noErr {
            self.reference = nil
            callbackBox = nil
        }
        return status
    }

    func deactivate() { callbackBox?.deactivate() }

    deinit {
        guard let reference else { return }
        callbackBox?.deactivate()
        let raw = UInt(bitPattern: reference)
        let callbackBox = callbackBox
        if Thread.isMainThread {
            if RemoveEventHandler(reference) != noErr {
                CarbonLifetimeQuarantine.retainHandler(
                    reference,
                    callbackBox: callbackBox
                )
            }
        } else {
            DispatchQueue.main.async {
                guard let reference = EventHandlerRef(bitPattern: raw) else { return }
                if RemoveEventHandler(reference) != noErr {
                    CarbonLifetimeQuarantine.retainHandler(
                        reference,
                        callbackBox: callbackBox
                    )
                }
            }
        }
    }
}

package struct CarbonHotKeyToken: @unchecked Sendable {
    fileprivate let lifetime: CarbonHotKeyLifetime?

    package static func fixture() -> Self { Self(lifetime: nil) }
}

package struct CarbonEventHandlerToken: @unchecked Sendable {
    fileprivate let lifetime: CarbonEventHandlerLifetime?
    private let deactivateAction: @Sendable () -> Void

    fileprivate init(lifetime: CarbonEventHandlerLifetime?) {
        self.lifetime = lifetime
        deactivateAction = { lifetime?.deactivate() }
    }

    private init(
        lifetime: CarbonEventHandlerLifetime?,
        deactivateAction: @escaping @Sendable () -> Void
    ) {
        self.lifetime = lifetime
        self.deactivateAction = deactivateAction
    }

    package static func fixture(
        callbackBox: CarbonCallbackBox? = nil
    ) -> Self {
        Self(
            lifetime: nil,
            deactivateAction: { callbackBox?.deactivate() }
        )
    }

    fileprivate func deactivate() { deactivateAction() }
}

package protocol CarbonHotKeyClient: Sendable {
    func installHandler(
        _ emit: @escaping @Sendable () -> Void
    ) -> (OSStatus, CarbonEventHandlerToken?)
    func removeHandler(_ token: CarbonEventHandlerToken) -> OSStatus
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        options: UInt32
    ) -> (OSStatus, CarbonHotKeyToken?)
    func unregister(_ token: CarbonHotKeyToken) -> OSStatus
}

package enum CarbonModifierConverter {
    package static func convert(_ rawValue: UInt32) throws -> UInt32 {
        let command = UInt32(NSEvent.ModifierFlags.command.rawValue)
        let option = UInt32(NSEvent.ModifierFlags.option.rawValue)
        let shift = UInt32(NSEvent.ModifierFlags.shift.rawValue)
        let control = UInt32(NSEvent.ModifierFlags.control.rawValue)
        let allowed = command | option | shift | control
        guard rawValue & ~allowed == 0 else {
            throw ShortcutRegistrationFailure.unsupportedModifiers
        }
        var converted: UInt32 = 0
        if rawValue & command != 0 { converted |= UInt32(cmdKey) }
        if rawValue & option != 0 { converted |= UInt32(optionKey) }
        if rawValue & shift != 0 { converted |= UInt32(shiftKey) }
        if rawValue & control != 0 { converted |= UInt32(controlKey) }
        return converted
    }
}

package actor GlobalShortcutRegistrar: GlobalShortcutRegistering {
    private let client: any CarbonHotKeyClient
    private let emit: @Sendable () -> Void
    private let operationGate = LifecycleOperationGate()
    private var handlerToken: CarbonEventHandlerToken?
    private var handlerActive = false
    private var token: CarbonHotKeyToken?

    package init(
        client: any CarbonHotKeyClient = SystemCarbonHotKeyClient(),
        emit: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.emit = emit
    }

    public func register(_ descriptor: ShortcutDescriptor) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        let modifiers = try CarbonModifierConverter.convert(descriptor.modifiers)
        let client = self.client

        if handlerActive {
            handlerToken?.deactivate()
            handlerActive = false
        }
        if let token {
            let status = await MainActor.run { client.unregister(token) }
            guard status == noErr else {
                throw ShortcutRegistrationFailure.unavailable
            }
            self.token = nil
        }
        if let handlerToken {
            let status = await MainActor.run {
                client.removeHandler(handlerToken)
            }
            guard status == noErr else {
                throw ShortcutRegistrationFailure.unavailable
            }
            self.handlerToken = nil
        }
        var installedHandlerForAttempt = false
        if handlerToken == nil {
            let emit = self.emit
            let (status, handlerToken) = await MainActor.run {
                client.installHandler(emit)
            }
            guard status == noErr, let handlerToken else {
                throw ShortcutRegistrationFailure.unavailable
            }
            self.handlerToken = handlerToken
            handlerActive = true
            installedHandlerForAttempt = true
        }
        let (status, token) = await MainActor.run {
            client.register(
                keyCode: descriptor.keyCode,
                modifiers: modifiers,
                options: UInt32(kEventHotKeyExclusive)
            )
        }
        guard status == noErr, let token else {
            if installedHandlerForAttempt, let handlerToken = self.handlerToken {
                handlerToken.deactivate()
                handlerActive = false
                let removalStatus = await MainActor.run {
                    client.removeHandler(handlerToken)
                }
                if removalStatus == noErr { self.handlerToken = nil }
            }
            if status == OSStatus(eventHotKeyExistsErr) {
                throw ShortcutRegistrationFailure.conflict
            }
            throw ShortcutRegistrationFailure.unavailable
        }
        self.token = token
    }

    public func unregister() async {
        await operationGate.acquire()
        defer { operationGate.release() }
        let client = self.client
        if handlerActive {
            handlerToken?.deactivate()
            handlerActive = false
        }
        if let token {
            let status = await MainActor.run { client.unregister(token) }
            guard status == noErr else { return }
            self.token = nil
        }
        if let handlerToken {
            let status = await MainActor.run {
                client.removeHandler(handlerToken)
            }
            if status == noErr { self.handlerToken = nil }
        }
    }
}

package final class CarbonCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var emit: (@Sendable () -> Void)?

    package init(emit: @escaping @Sendable () -> Void) { self.emit = emit }

    package func invokeIfActive() {
        let action = lock.withLock { emit }
        action?()
    }

    package func deactivate() {
        lock.withLock { emit = nil }
    }
}

private func glideTranslateHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == OSType(0x4754_4C44),
          hotKeyID.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<CarbonCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .invokeIfActive()
    return noErr
}

private struct SystemCarbonHotKeyClient: CarbonHotKeyClient, Sendable {
    func installHandler(
        _ emit: @escaping @Sendable () -> Void
    ) -> (OSStatus, CarbonEventHandlerToken?) {
        let box = CarbonCallbackBox(emit: emit)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            glideTranslateHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(box).toOpaque(),
            &reference
        )
        return status == noErr
            ? (
                status,
                CarbonEventHandlerToken(
                    lifetime: CarbonEventHandlerLifetime(
                        reference: reference,
                        callbackBox: box
                    )
                )
            )
            : (status, nil)
    }

    func removeHandler(_ token: CarbonEventHandlerToken) -> OSStatus {
        token.lifetime?.remove() ?? noErr
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        options: UInt32
    ) -> (OSStatus, CarbonHotKeyToken?) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4754_4C44), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(options),
            &reference
        )
        return status == noErr
            ? (
                status,
                CarbonHotKeyToken(
                    lifetime: CarbonHotKeyLifetime(reference: reference)
                )
            )
            : (status, nil)
    }

    func unregister(_ token: CarbonHotKeyToken) -> OSStatus {
        token.lifetime?.remove() ?? noErr
    }
}
