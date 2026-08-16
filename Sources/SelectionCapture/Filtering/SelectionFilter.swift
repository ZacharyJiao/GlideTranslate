import Foundation
import SharedSupport

package enum SelectionFilterFailure: Error, Equatable, Sendable {
    case empty
    case pureNumber
    case singlePunctuation
    case tooLong
}

package struct SelectionFilter: CapturedSelectionFiltering, Sendable {
    package let limit: Int

    package init(limit: Int) { self.limit = limit }

    package func apply(
        _ raw: String
    ) -> Result<String, SelectionFilterFailure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= limit else { return .failure(.tooLong) }
        if text.range(
            of: #"^[+-]?\p{Nd}+(?:[.,]\p{Nd}+)?$"#,
            options: .regularExpression
        ) != nil {
            return .failure(.pureNumber)
        }
        if text.count == 1,
           text.unicodeScalars.allSatisfy({
               switch $0.properties.generalCategory {
               case .connectorPunctuation, .dashPunctuation,
                    .openPunctuation, .closePunctuation,
                    .initialPunctuation, .finalPunctuation,
                    .otherPunctuation:
                   true
               default:
                   false
               }
           }) {
            return .failure(.singlePunctuation)
        }
        return .success(text)
    }

    package func filter(
        _ raw: String,
        limit: Int
    ) -> Result<String, SelectionAuthorizationFailure> {
        switch SelectionFilter(limit: limit).apply(raw) {
        case .success(let text): .success(text)
        case .failure: .failure(.noValidSelection)
        }
    }
}
