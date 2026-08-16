package struct PromptTemplateParser: Sendable {
    package init() {}

    package func parse(_ template: String) throws -> PromptSyntaxTree {
        var nodes: [PromptNode] = []
        var literal = ""
        var selectedTextCount = 0
        var index = template.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            nodes.append(.literal(literal))
            literal.removeAll(keepingCapacity: true)
        }

        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)

            if character == "{" {
                if next < template.endIndex, template[next] == "{" {
                    literal.append("{")
                    index = template.index(after: next)
                    continue
                }

                flushLiteral()
                guard let closingBrace = template[next...].firstIndex(of: "}") else {
                    throw PromptTemplateError.unterminatedPlaceholder
                }
                let token = template[next..<closingBrace]
                switch token {
                case "text":
                    selectedTextCount += 1
                    nodes.append(.selectedTextReference)
                case "source_language":
                    nodes.append(.sourceLanguageReference)
                case "target_language":
                    nodes.append(.targetLanguageReference)
                default:
                    throw PromptTemplateError.unknownPlaceholder
                }
                index = template.index(after: closingBrace)
                continue
            }

            if character == "}" {
                guard next < template.endIndex, template[next] == "}" else {
                    throw PromptTemplateError.unescapedClosingBrace
                }
                literal.append("}")
                index = template.index(after: next)
                continue
            }

            literal.append(character)
            index = next
        }

        flushLiteral()
        switch selectedTextCount {
        case 0:
            throw PromptTemplateError.missingSelectedText
        case 1:
            return PromptSyntaxTree(nodes: nodes)
        default:
            throw PromptTemplateError.repeatedSelectedText
        }
    }
}
