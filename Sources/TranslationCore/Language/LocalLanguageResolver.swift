import SharedSupport

package struct LocalLanguageResolver: Sendable {
    private let provider: any LanguageHypothesisProviding

    package init(
        provider: any LanguageHypothesisProviding = NaturalLanguageHypothesisProvider()
    ) {
        self.provider = provider
    }

    package func resolve(
        _ text: String,
        override explicitSource: LanguageChoice?
    ) -> LanguageChoice {
        if let explicitSource {
            return explicitSource
        }
        guard let hypothesis = provider.leadingHypothesis(for: text),
              hypothesis.confidence >= 0.60
        else {
            return .automatic
        }
        return .identified(hypothesis.languageCode)
    }

    package func resolveTarget(
        explicitRequest: LanguageChoice?,
        presetOverride: LanguageChoice?,
        globalDefault: LanguageChoice
    ) -> LanguageChoice {
        explicitRequest ?? presetOverride ?? globalDefault
    }
}
