import ModelProviders
import SharedSupport

public enum TranslationCoreFactory {
    public static func makeEngine(
        provider: any ProviderService,
        preflight: any ProviderPreflight,
        clock: any AppClock = SystemAppClock()
    ) -> any TranslationEngine {
        DefaultTranslationEngine(
            provider: provider,
            preflight: preflight,
            clock: clock
        )
    }
}
