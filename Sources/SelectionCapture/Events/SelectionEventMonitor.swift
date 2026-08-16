import AppKit
import Foundation
import SharedSupport

public protocol SelectionTriggerMonitoring: Sendable {
    func start(mouseEnabled: Bool, keyboardEnabled: Bool) async throws
    func stop() async
}

public enum SelectionMonitorFailure: Error, Equatable, Sendable {
    case unavailable
}

package struct SelectionEventMonitorToken: Hashable, Sendable {
    package let id: Int
}

package protocol SelectionEventMonitorClient: Sendable {
    func addMouseUpMonitor(
        _ handler: @escaping @Sendable () -> Void
    ) -> SelectionEventMonitorToken?
    func addKeyDownMonitor(
        _ handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags) -> Void
    ) -> SelectionEventMonitorToken?
    func removeMonitor(_ token: SelectionEventMonitorToken)
}

package enum ObservedSelectionEvent: Sendable {
    case mouseUp
    case keyDown(code: UInt16, flags: NSEvent.ModifierFlags)
    case programmaticSelectionChanged
}

package actor SelectionEventMonitor: SelectionTriggerMonitoring {
    private let client: any SelectionEventMonitorClient
    private let emit: @Sendable (CaptureTrigger) -> Void
    private let operationGate = LifecycleOperationGate()
    private var configuration: (mouse: Bool, keyboard: Bool)?
    private var mouseToken: SelectionEventMonitorToken?
    private var keyboardToken: SelectionEventMonitorToken?

    package init(
        client: any SelectionEventMonitorClient = SystemSelectionEventMonitorClient(),
        emit: @escaping @Sendable (CaptureTrigger) -> Void
    ) {
        self.client = client
        self.emit = emit
    }

    public func start(
        mouseEnabled: Bool,
        keyboardEnabled: Bool
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        if let configuration,
           configuration.mouse == mouseEnabled,
           configuration.keyboard == keyboardEnabled {
            return
        }
        await removeInstalledMonitors()
        configuration = nil

        if mouseEnabled {
            let client = self.client
            let emit = self.emit
            guard let token = await MainActor.run(body: {
                client.addMouseUpMonitor { emit(.mouse) }
            }) else {
                throw SelectionMonitorFailure.unavailable
            }
            mouseToken = token
        }
        if keyboardEnabled {
            let client = self.client
            let emit = self.emit
            guard let token = await MainActor.run(body: {
                client.addKeyDownMonitor { code, flags in
                    guard KnownSelectionKey.classify(
                        keyCode: code,
                        flags: flags
                    ) != nil else { return }
                    emit(.keyboardSelection)
                }
            }) else {
                await removeInstalledMonitors()
                throw SelectionMonitorFailure.unavailable
            }
            keyboardToken = token
        }
        configuration = (mouseEnabled, keyboardEnabled)
    }

    public func stop() async {
        await operationGate.acquire()
        defer { operationGate.release() }
        await removeInstalledMonitors()
        configuration = nil
    }

    package func handle(
        _ event: ObservedSelectionEvent,
        keyboardEnabled: Bool
    ) {
        switch event {
        case .mouseUp:
            emit(.mouse)
        case .keyDown(let code, let flags)
            where keyboardEnabled
                && KnownSelectionKey.classify(keyCode: code, flags: flags) != nil:
            emit(.keyboardSelection)
        case .keyDown, .programmaticSelectionChanged:
            break
        }
    }

    private func removeInstalledMonitors() async {
        let mouseToken = self.mouseToken
        let keyboardToken = self.keyboardToken
        self.mouseToken = nil
        self.keyboardToken = nil
        let client = self.client
        await MainActor.run {
            if let mouseToken { client.removeMonitor(mouseToken) }
            if let keyboardToken { client.removeMonitor(keyboardToken) }
        }
    }
}

private final class SystemSelectionEventMonitorClient:
    SelectionEventMonitorClient, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var monitors: [SelectionEventMonitorToken: Any] = [:]

    func addMouseUpMonitor(
        _ handler: @escaping @Sendable () -> Void
    ) -> SelectionEventMonitorToken? {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp],
            handler: { _ in handler() }
        ) else { return nil }
        return store(monitor)
    }

    func addKeyDownMonitor(
        _ handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags) -> Void
    ) -> SelectionEventMonitorToken? {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown],
            handler: { event in
                handler(event.keyCode, event.modifierFlags)
            }
        ) else { return nil }
        return store(monitor)
    }

    func removeMonitor(_ token: SelectionEventMonitorToken) {
        let monitor = lock.withLock { monitors.removeValue(forKey: token) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func store(_ monitor: Any) -> SelectionEventMonitorToken {
        lock.withLock {
            nextID += 1
            let token = SelectionEventMonitorToken(id: nextID)
            monitors[token] = monitor
            return token
        }
    }
}
