import NaturalLanguage

package protocol LanguageHypothesisProviding: Sendable {
    func leadingHypothesis(
        for text: String
    ) -> (languageCode: String, confidence: Double)?
}

package struct NaturalLanguageHypothesisProvider:
    LanguageHypothesisProviding,
    Sendable
{
    package init() {}

    package func leadingHypothesis(
        for text: String
    ) -> (languageCode: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(
                  withMaximum: 1
              )[language]
        else {
            return nil
        }
        return (language.rawValue, confidence)
    }
}
