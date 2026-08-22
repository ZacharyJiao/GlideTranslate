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
    case traversalExhausted
    case traversalCannotComplete
}

package protocol AXSystemAccessing: Sendable {
    func isTrusted() -> Bool
    func makeApplication(pid: pid_t) -> AXElementToken
    func setMessagingTimeout(
        _ seconds: Float,
        for element: AXElementToken
    ) throws
    func enableManualAccessibility(of application: AXElementToken) throws
    func focusedElement(of application: AXElementToken) throws -> AXElementToken
    func systemWideFocusedElement(expectedPID: pid_t) throws -> AXElementToken
    func selectionElementFallback(of application: AXElementToken) throws -> AXElementToken
    func selectedText(of element: AXElementToken) throws -> String
    func selectedTextFromTextMarkerRange(
        of element: AXElementToken
    ) throws -> String
    func selectedTextFromValueRange(of element: AXElementToken) throws -> String
    func selectedBoundsTopLeftGlobal(
        of element: AXElementToken
    ) throws -> CGRect?
}

package final class SystemAXClient: AXSelectionClient, @unchecked Sendable {
    private let system: any AXSystemAccessing
    private let diagnosticHandler: SelectionAXDiagnosticHandler

    package convenience init() {
        self.init(diagnosticHandler: { _ in })
    }

    package convenience init(
        diagnosticHandler: @escaping SelectionAXDiagnosticHandler
    ) {
        self.init(
            system: DefaultAXSystem(diagnosticHandler: diagnosticHandler),
            diagnosticHandler: diagnosticHandler
        )
    }

    package init(
        system: any AXSystemAccessing,
        diagnosticHandler: @escaping SelectionAXDiagnosticHandler = { _ in }
    ) {
        self.system = system
        self.diagnosticHandler = diagnosticHandler
    }

    package func readSelection(pid: pid_t) throws -> AXSelectionMaterial {
        guard system.isTrusted() else { throw AXReadFailure.notTrusted }

        let application = system.makeApplication(pid: pid)
        try perform({
            try system.setMessagingTimeout(1.0, for: application)
        }, unavailable: .focusedElementUnavailable)
        do {
            try system.enableManualAccessibility(of: application)
        } catch AXOperationFailure.apiDisabled {
            throw AXReadFailure.notTrusted
        } catch {
            // Optional Electron compatibility capability. Native applications
            // commonly do not expose this attribute and must keep using the
            // ordinary Accessibility path.
        }
        let focused: AXElementToken
        do {
            focused = try perform({
                try focusedElementWithDiagnostic(of: application)
            }, unavailable: .focusedElementUnavailable)
        } catch AXReadFailure.focusedElementUnavailable {
            do {
                focused = try perform({
                    try systemWideFocusedElementWithDiagnostic(expectedPID: pid)
                }, unavailable: .focusedElementUnavailable)
            } catch AXReadFailure.focusedElementUnavailable {
                focused = try perform({
                    try descendantSelectionWithDiagnostic(of: application)
                }, unavailable: .focusedElementUnavailable)
            }
        }
        try perform({
            try system.setMessagingTimeout(1.0, for: focused)
        }, unavailable: .focusedElementUnavailable)
        let selectedElement: AXElementToken
        let text: String
        do {
            text = try perform({
                try selectedTextWithTextMarkerFallback(of: focused)
            }, unavailable: .attributeUnsupported)
            selectedElement = focused
        } catch AXReadFailure.attributeUnsupported {
            selectedElement = try perform({
                try descendantSelectionWithDiagnostic(of: application)
            }, unavailable: .focusedElementUnavailable)
            try perform({
                try system.setMessagingTimeout(1.0, for: selectedElement)
            }, unavailable: .focusedElementUnavailable)
            text = try perform({
                try selectedTextWithTextMarkerFallback(of: selectedElement)
            }, unavailable: .attributeUnsupported)
        }
        guard !text.isEmpty else { throw AXReadFailure.emptyValue }

        let topLeftBounds: CGRect?
        do {
            topLeftBounds = try system.selectedBoundsTopLeftGlobal(of: selectedElement)
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

    private func selectedTextWithTextMarkerFallback(
        of element: AXElementToken
    ) throws -> String {
        do {
            let directText = try directSelectionWithDiagnostic(of: element)
            if !directText.isEmpty { return directText }
        } catch AXOperationFailure.unavailable {
        } catch {
            throw error
        }
        do {
            let markerText = try markerSelectionWithDiagnostic(of: element)
            if !markerText.isEmpty { return markerText }
        } catch AXOperationFailure.unavailable {
        } catch {
            throw error
        }
        return try valueSelectionWithDiagnostic(of: element)
    }

    private func focusedElementWithDiagnostic(
        of application: AXElementToken
    ) throws -> AXElementToken {
        do {
            let element = try system.focusedElement(of: application)
            diagnosticHandler(.focusedLookupApplicationSucceeded)
            return element
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.focusedLookupApplicationPermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.focusedLookupApplicationCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.focusedLookupApplicationUnsupported)
            throw AXOperationFailure.unavailable
        }
    }

    private func systemWideFocusedElementWithDiagnostic(
        expectedPID: pid_t
    ) throws -> AXElementToken {
        do {
            let element = try system.systemWideFocusedElement(expectedPID: expectedPID)
            diagnosticHandler(.focusedLookupSystemWideSucceeded)
            return element
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.focusedLookupSystemWidePermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.focusedLookupSystemWideCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.focusedLookupSystemWideUnsupported)
            throw AXOperationFailure.unavailable
        }
    }

    private func descendantSelectionWithDiagnostic(
        of application: AXElementToken
    ) throws -> AXElementToken {
        do {
            let element = try system.selectionElementFallback(of: application)
            diagnosticHandler(.focusedLookupDescendantSucceeded)
            diagnosticHandler(.descendantTraversalSucceeded)
            return element
        } catch AXOperationFailure.traversalExhausted {
            diagnosticHandler(.focusedLookupDescendantUnsupported)
            diagnosticHandler(.descendantTraversalExhausted)
            throw AXOperationFailure.unavailable
        } catch AXOperationFailure.traversalCannotComplete {
            diagnosticHandler(.focusedLookupDescendantCannotComplete)
            diagnosticHandler(.descendantTraversalCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.focusedLookupDescendantPermission)
            diagnosticHandler(.descendantTraversalPermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.focusedLookupDescendantCannotComplete)
            diagnosticHandler(.descendantTraversalCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.focusedLookupDescendantUnsupported)
            diagnosticHandler(.descendantTraversalExhausted)
            throw AXOperationFailure.unavailable
        }
    }

    private func directSelectionWithDiagnostic(
        of element: AXElementToken
    ) throws -> String {
        do {
            let text = try system.selectedText(of: element)
            diagnosticHandler(
                text.isEmpty
                    ? .directSelectionEmpty
                    : .directSelectionSucceeded
            )
            return text
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.directSelectionPermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.directSelectionCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.directSelectionUnsupported)
            throw AXOperationFailure.unavailable
        }
    }

    private func markerSelectionWithDiagnostic(
        of element: AXElementToken
    ) throws -> String {
        do {
            let text = try system.selectedTextFromTextMarkerRange(of: element)
            diagnosticHandler(
                text.isEmpty
                    ? .markerSelectionEmpty
                    : .markerSelectionSucceeded
            )
            return text
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.markerSelectionPermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.markerSelectionCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.markerSelectionUnsupported)
            throw AXOperationFailure.unavailable
        }
    }

    private func valueSelectionWithDiagnostic(
        of element: AXElementToken
    ) throws -> String {
        do {
            let text = try system.selectedTextFromValueRange(of: element)
            diagnosticHandler(
                text.isEmpty
                    ? .valueSelectionEmpty
                    : .valueSelectionSucceeded
            )
            return text
        } catch AXOperationFailure.apiDisabled {
            diagnosticHandler(.valueSelectionPermission)
            throw AXOperationFailure.apiDisabled
        } catch AXOperationFailure.cannotComplete {
            diagnosticHandler(.valueSelectionCannotComplete)
            throw AXOperationFailure.cannotComplete
        } catch {
            diagnosticHandler(.valueSelectionUnsupported)
            throw AXOperationFailure.unavailable
        }
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
    private let diagnosticHandler: SelectionAXDiagnosticHandler

    init(diagnosticHandler: @escaping SelectionAXDiagnosticHandler = { _ in }) {
        self.diagnosticHandler = diagnosticHandler
    }

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

    func enableManualAccessibility(of application: AXElementToken) throws {
        let error = AXUIElementSetAttributeValue(
            rawElement(application),
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        try requireSuccess(error)
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

    func systemWideFocusedElement(expectedPID: pid_t) throws -> AXElementToken {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        try requireSuccess(error)
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw AXOperationFailure.unavailable
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
              focusedPID == expectedPID else {
            throw AXOperationFailure.unavailable
        }
        return AXElementToken(raw: focused)
    }

    func selectionElementFallback(of application: AXElementToken) throws -> AXElementToken {
        var windowsValue: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(
            rawElement(application),
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        if windowsError == .apiDisabled {
            throw AXOperationFailure.apiDisabled
        }
        if windowsError == .cannotComplete {
            diagnosticHandler(.descendantTraversalCannotComplete)
            throw AXOperationFailure.traversalCannotComplete
        }

        var queue = [(rawElement(application), 0)]
        if windowsError == .success, let windows = windowsValue as? [AXUIElement] {
            queue.append(contentsOf: windows.map { ($0, 0) })
        }
        var cursor = 0
        let maximumDepth = 16
        let maximumElements = 800

        while cursor < queue.count, cursor < maximumElements {
            let (element, depth) = queue[cursor]
            cursor += 1

            do {
                if try hasNonemptySelection(element) {
                    return AXElementToken(raw: element)
                }
            } catch AXOperationFailure.cannotComplete {
                throw AXOperationFailure.traversalCannotComplete
            }
            guard depth < maximumDepth else { continue }

            for attribute in [
                kAXChildrenAttribute,
                kAXVisibleChildrenAttribute,
                "AXContents",
            ] {
                guard queue.count < maximumElements else { break }
                var childrenValue: CFTypeRef?
                let childrenError = AXUIElementCopyAttributeValue(
                    element,
                    attribute as CFString,
                    &childrenValue
                )
                switch childrenError {
                case .success:
                    if let children = childrenValue as? [AXUIElement] {
                        queue.append(contentsOf: children.prefix(
                            maximumElements - queue.count
                        ).map { ($0, depth + 1) })
                    }
                case .apiDisabled:
                    throw AXOperationFailure.apiDisabled
                case .cannotComplete:
                    diagnosticHandler(.descendantTraversalCannotComplete)
                    continue
                default:
                    continue
                }
            }
        }
        throw AXOperationFailure.traversalExhausted
    }

    private func hasNonemptySelection(_ element: AXUIElement) throws -> Bool {
        let token = AXElementToken(raw: element)
        do {
            if try !selectedText(of: token).isEmpty { return true }
        } catch AXOperationFailure.unavailable {
        } catch {
            throw error
        }
        do {
            if try !selectedTextFromTextMarkerRange(of: token).isEmpty { return true }
        } catch AXOperationFailure.unavailable {
        } catch {
            throw error
        }
        do {
            return try !selectedTextFromValueRange(of: token).isEmpty
        } catch AXOperationFailure.unavailable {
            return false
        } catch {
            throw error
        }
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

    func selectedTextFromTextMarkerRange(
        of element: AXElementToken
    ) throws -> String {
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            rawElement(element),
            "AXSelectedTextMarkerRange" as CFString,
            &rangeValue
        )
        try requireSuccess(rangeError)
        guard let rangeValue,
              CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID() else {
            throw AXOperationFailure.unavailable
        }

        var textValue: CFTypeRef?
        let textError = AXUIElementCopyParameterizedAttributeValue(
            rawElement(element),
            "AXStringForTextMarkerRange" as CFString,
            rangeValue,
            &textValue
        )
        try requireSuccess(textError)
        guard let text = textValue as? String else {
            throw AXOperationFailure.unavailable
        }
        return text
    }

    func selectedTextFromValueRange(of element: AXElementToken) throws -> String {
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            rawElement(element),
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        try requireSuccess(rangeError)
        guard let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            throw AXOperationFailure.unavailable
        }

        var textValue: CFTypeRef?
        let textError = AXUIElementCopyParameterizedAttributeValue(
            rawElement(element),
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        )
        try requireSuccess(textError)
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
