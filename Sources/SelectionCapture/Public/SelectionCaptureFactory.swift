import SharedSupport

public struct SelectionCaptureServices: Sendable {
    public let systemSelectionProcessor: any SystemSelectionProcessing
    public let authorizationGate: any SelectionAuthorizationGate

    public init(
        systemSelectionProcessor: any SystemSelectionProcessing,
        authorizationGate: any SelectionAuthorizationGate
    ) {
        self.systemSelectionProcessor = systemSelectionProcessor
        self.authorizationGate = authorizationGate
    }
}

public enum SelectionCaptureFactory {
    public static func makeAuthorizationServices(
        snapshotReader: any ProviderSnapshotReading,
        clock: any AppClock = SystemAppClock(),
        diagnosticHandler: @escaping SelectionAXDiagnosticHandler = { _ in }
    ) -> SelectionCaptureServices {
        let foregroundReader = DefaultForegroundApplicationReader()
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: foregroundReader,
            systemReader: AccessibilitySelectionReader(
                diagnosticHandler: diagnosticHandler
            ),
            clipboardReader: LazyShortcutClipboardReader(
                factory: SystemShortcutClipboardReaderFactory(clock: clock)
            ),
            snapshotReader: snapshotReader,
            selectionFilter: SelectionFilter(limit: 2_000),
            duplicateChecker: DuplicateSuppressor(),
            diagnosticHandler: diagnosticHandler
        )
        let pipeline = SystemSelectionPipeline(
            foregroundReader: foregroundReader,
            gate: gate,
            debouncer: SelectionDebouncer(
                delay: .milliseconds(350),
                clock: clock
            )
        )
        return SelectionCaptureServices(
            systemSelectionProcessor: pipeline,
            authorizationGate: gate
        )
    }

    public static func makeTriggerMonitor(
        emit: @escaping @Sendable (CaptureTrigger) -> Void,
        onTriggerReceived: @escaping @Sendable (CaptureTrigger) -> Void = { _ in }
    ) -> any SelectionTriggerMonitoring {
        SelectionEventMonitor(
            emit: emit,
            onTriggerReceived: onTriggerReceived
        )
    }

    public static func makeShortcutRegistrar(
        emit: @escaping @Sendable () -> Void,
        onShortcutReceived: @escaping @Sendable () -> Void = {}
    ) -> any GlobalShortcutRegistering {
        GlobalShortcutRegistrar(
            emit: emit,
            onShortcutReceived: onShortcutReceived
        )
    }
}
