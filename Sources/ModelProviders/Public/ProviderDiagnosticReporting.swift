import SharedSupport

public protocol ProviderDiagnosticReporting: Sendable {
    func record(_ event: ProviderDiagnosticEvent) async
}
