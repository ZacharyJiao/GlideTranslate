import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

package struct AXElementToken: @unchecked Sendable {
    fileprivate let raw: AnyObject
    package let identifier: ObjectIdentifier
    package init(raw: AnyObject) {
        self.raw = raw
        identifier = ObjectIdentifier(raw)
    }
}

package enum AXOperationFailure: Error, Equatable, Sendable {
    case apiDisabled
    case cannotComplete
    case unavailable
}

package protocol AXSystemAccessing: Sendable {
    func isTrusted() -> Bool
    func makeApplication(pid: pid_t) -> AXElementToken
    func setMessagingTimeout(
        _ seconds: Float,
        for element: AXElementToken
    ) throws
    func focusedElement(of application: AXElementToken) throws -> AXElementToken
    func selectedText(of element: AXElementToken) throws -> String
    func selectedBoundsTopLeftGlobal(
        of element: AXElementToken
    ) throws -> CGRect?
}

package final class SystemAXClient: AXSelectionClient, @unchecked Sendable {
    private let system: any AXSystemAccessing

    package convenience init() {
        self.init(system: DefaultAXSystem())
    }

    package init(system: any AXSystemAccessing) {
        self.system = system
    }

    package func readSelection(pid: pid_t) throws -> AXSelectionMaterial {
        guard system.isTrusted() else { throw AXReadFailure.notTrusted }

        let application = system.makeApplication(pid: pid)
        try perform({
            try system.setMessagingTimeout(1.0, for: application)
        }, unavailable: .focusedElementUnavailable)
        let focused = try perform({
            try system.focusedElement(of: application)
        }, unavailable: .focusedElementUnavailable)
        try perform({
            try system.setMessagingTimeout(1.0, for: focused)
        }, unavailable: .focusedElementUnavailable)
        let text = try perform({
            try system.selectedText(of: focused)
        }, unavailable: .attributeUnsupported)
        guard !text.isEmpty else { throw AXReadFailure.emptyValue }

        let topLeftBounds: CGRect?
        do {
            topLeftBounds = try system.selectedBoundsTopLeftGlobal(of: focused)
        } catch AXOperationFailure.apiDisabled {
            throw AXReadFailure.notTrusted
        } catch {
            topLeftBounds = nil
        }

        let displayRect: CGRect?
        if let topLeftBounds,
           let displays = AXCoordinateConverter.currentDisplays() {
            displayRect = AXCoordinateConverter.appKitGlobalRect(
                topLeftBounds,
                displays: displays
            )
        } else {
            displayRect = nil
        }
        return AXSelectionMaterial(text: text, displayRect: displayRect)
    }

    private func perform<T>(
        _ operation: () throws -> T,
        unavailable: AXReadFailure
    ) throws -> T {
        do {
            return try operation()
        } catch AXOperationFailure.apiDisabled {
            throw AXReadFailure.notTrusted
        } catch AXOperationFailure.cannotComplete {
            throw AXReadFailure.cannotComplete
        } catch {
            throw unavailable
        }
    }
}

private final class DefaultAXSystem: AXSystemAccessing, @unchecked Sendable {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func makeApplication(pid: pid_t) -> AXElementToken {
        AXElementToken(raw: AXUIElementCreateApplication(pid))
    }

    func setMessagingTimeout(
        _ seconds: Float,
        for element: AXElementToken
    ) throws {
        try requireSuccess(AXUIElementSetMessagingTimeout(
            rawElement(element),
            seconds
        ))
    }

    func focusedElement(
        of application: AXElementToken
    ) throws -> AXElementToken {
        var focusedValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            rawElement(application),
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        try requireSuccess(error)
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw AXOperationFailure.unavailable
        }
        return AXElementToken(
            raw: unsafeDowncast(focusedValue, to: AXUIElement.self)
        )
    }

    func selectedText(of element: AXElementToken) throws -> String {
        var textValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            rawElement(element),
            kAXSelectedTextAttribute as CFString,
            &textValue
        )
        try requireSuccess(error)
        guard let text = textValue as? String else {
            throw AXOperationFailure.unavailable
        }
        return text
    }

    func selectedBoundsTopLeftGlobal(
        of element: AXElementToken
    ) throws -> CGRect? {
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            rawElement(element),
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        if rangeError == .apiDisabled {
            throw AXOperationFailure.apiDisabled
        }
        guard rangeError == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let boundsError = AXUIElementCopyParameterizedAttributeValue(
            rawElement(element),
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        if boundsError == .apiDisabled {
            throw AXOperationFailure.apiDisabled
        }
        guard boundsError == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        let axValue = unsafeDowncast(boundsValue, to: AXValue.self)
        guard AXValueGetValue(axValue, .cgRect, &rect),
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.width >= 0,
              rect.height >= 0 else {
            return nil
        }
        return rect
    }

    private func rawElement(_ token: AXElementToken) -> AXUIElement {
        unsafeDowncast(token.raw, to: AXUIElement.self)
    }

    private func requireSuccess(_ error: AXError) throws {
        switch error {
        case .success:
            return
        case .apiDisabled:
            throw AXOperationFailure.apiDisabled
        case .cannotComplete:
            throw AXOperationFailure.cannotComplete
        default:
            throw AXOperationFailure.unavailable
        }
    }
}
