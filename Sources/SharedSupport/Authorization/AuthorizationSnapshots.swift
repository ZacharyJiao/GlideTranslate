public struct CapturePolicySnapshot: Sendable {
    public let automaticCaptureEnabled: Bool
    public let mouseSelectionEnabled: Bool
    public let keyboardSelectionEnabled: Bool
    public let generalAllowlist: Set<ApplicationIdentity>
    public let offDeviceAllowlist: Set<ApplicationIdentity>
    public let clipboardFallbackEnabled: Bool
    public let selectionDebounceMilliseconds: Int
    public let selectionCharacterLimit: Int

    public init(
        automaticCaptureEnabled: Bool,
        mouseSelectionEnabled: Bool,
        keyboardSelectionEnabled: Bool,
        generalAllowlist: Set<ApplicationIdentity>,
        offDeviceAllowlist: Set<ApplicationIdentity>,
        clipboardFallbackEnabled: Bool,
        selectionDebounceMilliseconds: Int,
        selectionCharacterLimit: Int
    ) {
        self.automaticCaptureEnabled = automaticCaptureEnabled
        self.mouseSelectionEnabled = mouseSelectionEnabled
        self.keyboardSelectionEnabled = keyboardSelectionEnabled
        self.generalAllowlist = generalAllowlist
        self.offDeviceAllowlist = offDeviceAllowlist
        self.clipboardFallbackEnabled = clipboardFallbackEnabled
        self.selectionDebounceMilliseconds = selectionDebounceMilliseconds
        self.selectionCharacterLimit = selectionCharacterLimit
    }
}

public struct SendPolicySnapshot: Sendable {
    public let expectedProvider: ProviderDestinationSnapshot

    public init(expectedProvider: ProviderDestinationSnapshot) {
        self.expectedProvider = expectedProvider
    }
}
