import PrivacyStorage

public struct ModelProviderServices: Sendable {
    public let preflight: any ProviderPreflight
    public let confirmation: any ProviderConfirmationService
    public let service: any ProviderService
    public let inspection: any ProviderInspection

    public init(
        preflight: any ProviderPreflight,
        confirmation: any ProviderConfirmationService,
        service: any ProviderService,
        inspection: any ProviderInspection
    ) {
        self.preflight = preflight
        self.confirmation = confirmation
        self.service = service
        self.inspection = inspection
    }
}

public enum ModelProviderFactory {
    public static func make(
        vault: ProviderVaultHandle,
        diagnostics: any ProviderDiagnosticReporting
    ) -> ModelProviderServices {
        let resolver = SystemAddressResolver()
        let preflight = DefaultProviderPreflight(
            repository: vault.access,
            resolver: resolver
        )
        let confirmation = DefaultProviderConfirmationService(
            repository: vault.access,
            resolver: resolver,
            committer: vault.confirmation
        )
        let connectionFactory = NetworkConnectionFactory()
        let transport = PinnedHTTPTransport(factory: connectionFactory)
        let ollama = OllamaProvider(
            transport: transport,
            resolver: resolver,
            access: vault.access,
            diagnostics: diagnostics
        )
        let compatible = OpenAICompatibleProvider(
            transport: transport,
            resolver: resolver,
            access: vault.access,
            diagnostics: diagnostics,
            connectionFactory: connectionFactory
        )
        let service = DefaultProviderService(
            preflight: preflight,
            access: vault.access,
            ollama: ollama,
            compatible: compatible
        )
        return ModelProviderServices(
            preflight: preflight,
            confirmation: confirmation,
            service: service,
            inspection: service
        )
    }
}
