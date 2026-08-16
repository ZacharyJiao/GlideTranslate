package enum PromptNode: Equatable, Sendable {
    case literal(String)
    case selectedTextReference
    case sourceLanguageReference
    case targetLanguageReference
}

package struct PromptSyntaxTree: Equatable, Sendable {
    package let nodes: [PromptNode]
}

package enum PromptTemplateError: Error, Equatable, Sendable {
    case missingSelectedText
    case repeatedSelectedText
    case unknownPlaceholder
    case unterminatedPlaceholder
    case unescapedClosingBrace
}
