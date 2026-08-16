import SharedSupport

package actor SystemSelectionPipeline: SystemSelectionProcessing {
    private struct DuplicateScope: Equatable, Sendable {
        let automaticCaptureEnabled: Bool
        let generalAllowlist: Set<ApplicationIdentity>
        let offDeviceAllowlist: Set<ApplicationIdentity>
        let providerConfigurationID: ProviderConfigurationID

        init(
            policy: CapturePolicySnapshot,
            provider: ProviderDestinationSnapshot
        ) {
            automaticCaptureEnabled = policy.automaticCaptureEnabled
            generalAllowlist = policy.generalAllowlist
            offDeviceAllowlist = policy.offDeviceAllowlist
            providerConfigurationID = provider.configurationID
        }
    }

    private let foregroundReader: any ForegroundApplicationReading
    private let gate: any ResettableSelectionAuthorizationGate
    private let debouncer: SelectionDebouncer
    private var duplicateScope: DuplicateScope?

    package init(
        foregroundReader: any ForegroundApplicationReading,
        gate: any ResettableSelectionAuthorizationGate,
        debouncer: SelectionDebouncer
    ) {
        self.foregroundReader = foregroundReader
        self.gate = gate
        self.debouncer = debouncer
    }

    package func process(
        trigger: CaptureTrigger,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome {
        switch trigger {
        case .manualInput:
            await debouncer.cancel()
            return .manualInputRequired
        case .shortcut:
            await debouncer.cancel()
        case .mouse, .keyboardSelection:
            let milliseconds = max(0, policy.selectionDebounceMilliseconds)
            guard await debouncer.wait(for: .milliseconds(milliseconds)) else {
                return .rejected(.cancelled)
            }
        }

        await resetDuplicateStateIfNeeded(policy: policy, provider: provider)

        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        let foregroundResult = await foregroundReader.current()
        guard !Task.isCancelled else {
            return .rejected(.cancelled)
        }
        guard case .success(let context) = foregroundResult else {
            if case .failure(let failure) = foregroundResult {
                return .rejected(failure)
            }
            return .rejected(.unsupportedApplication)
        }
        return await gate.authorizeSystemSelection(
            trigger: trigger,
            context: context,
            options: options,
            policy: policy,
            provider: provider
        )
    }

    private func resetDuplicateStateIfNeeded(
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async {
        let scope = DuplicateScope(policy: policy, provider: provider)
        guard scope != duplicateScope else { return }
        duplicateScope = scope
        await gate.resetDuplicateState()
    }
}
