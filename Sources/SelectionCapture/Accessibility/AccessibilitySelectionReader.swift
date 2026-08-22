import CoreGraphics
import Darwin
import SharedSupport

package enum AXReadFailure: Error, Equatable, Sendable {
    case notTrusted
    case focusedElementUnavailable
    case attributeUnsupported
    case cannotComplete
    case emptyValue
}

package struct AXSelectionMaterial: Equatable, Sendable {
    package let text: String
    package let displayRect: CGRect?
}

package protocol AXSelectionClient: Sendable {
    func readSelection(pid: pid_t) throws -> AXSelectionMaterial
}

package struct AccessibilitySelectionReader: SystemSelectionReading, Sendable {
    private let client: any AXSelectionClient
    private let lane: AXExecutionLane

    package init(
        client: any AXSelectionClient = SystemAXClient(),
        lane: AXExecutionLane = AXExecutionLane()
    ) {
        self.client = client
        self.lane = lane
    }

    package init(
        diagnosticHandler: @escaping SelectionAXDiagnosticHandler,
        lane: AXExecutionLane = AXExecutionLane()
    ) {
        self.init(
            client: SystemAXClient(diagnosticHandler: diagnosticHandler),
            lane: lane
        )
    }

    package func readSelection(
        from context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        await read(context: context)
    }

    package func read(
        context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        do {
            let client = self.client
            let pid = context.processIdentifier
            let material = try await lane.run {
                try client.readSelection(pid: pid)
            }
            return .success(CapturedSelection(
                text: material.text,
                displayRect: material.displayRect
            ))
        } catch let failure as AXReadFailure {
            return .failure(failure.authorizationFailure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.unsupportedApplication)
        }
    }
}

private extension AXReadFailure {
    var authorizationFailure: SelectionAuthorizationFailure {
        switch self {
        case .notTrusted: .accessibilityPermissionMissing
        case .focusedElementUnavailable, .attributeUnsupported:
            .unsupportedApplication
        case .cannotComplete: .selectionReadTimedOut
        case .emptyValue: .noValidSelection
        }
    }
}
