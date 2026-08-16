import Foundation

struct SafeMarkdownParser: Sendable {
    static let maximumInputBytes = 4 * 1_024 * 1_024
    static let maximumNodeCount = 20_000
    static let truncationNotice = "[Output truncated locally]"

    func parse(_ input: String) -> SafeMarkdownDocument {
        let bounded = Self.boundedPrefix(of: input)
        guard !bounded.truncated else {
            return Self.truncatedDocument(literalPrefix: bounded.value)
        }

        let normalized = bounded.value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let nodes = parseBlocks(normalized) else {
            return Self.truncatedDocument(literalPrefix: bounded.value)
        }
        return SafeMarkdownDocument(nodes: nodes)
    }

    private func parseBlocks(_ input: String) -> [SafeMarkdownNode]? {
        let lines = input.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var nodes: [SafeMarkdownNode] = []
        var nodeCount = 0
        var lineIndex = lines.startIndex

        while lineIndex < lines.endIndex {
            if lines[lineIndex].isEmpty {
                lineIndex += 1
                continue
            }

            if lines[lineIndex].hasPrefix("- ") {
                var items: [[InlineNode]] = []
                while lineIndex < lines.endIndex,
                      lines[lineIndex].hasPrefix("- ") {
                    let content = String(lines[lineIndex].dropFirst(2))
                    let remaining = Self.maximumNodeCount - nodeCount - 2
                    guard remaining >= 0,
                          let inlines = parseInline(content, limit: remaining) else {
                        return nil
                    }
                    items.append(inlines)
                    nodeCount += 1 + inlines.count
                    lineIndex += 1
                }
                nodeCount += 1
                guard nodeCount <= Self.maximumNodeCount else { return nil }
                nodes.append(.list(items))
                continue
            }

            var paragraphLines: [Substring] = []
            while lineIndex < lines.endIndex,
                  !lines[lineIndex].isEmpty,
                  !lines[lineIndex].hasPrefix("- ") {
                paragraphLines.append(lines[lineIndex])
                lineIndex += 1
            }
            let paragraph = paragraphLines.joined(separator: "\n")
            let remaining = Self.maximumNodeCount - nodeCount - 1
            guard remaining >= 0,
                  let inlines = parseInline(paragraph, limit: remaining) else {
                return nil
            }
            nodeCount += 1 + inlines.count
            guard nodeCount <= Self.maximumNodeCount else { return nil }
            nodes.append(.paragraph(inlines))
        }

        return nodes
    }

    private func parseInline(_ input: String, limit: Int) -> [InlineNode]? {
        guard !input.contains("```") else {
            return limit >= 1 ? [.text(input)] : nil
        }

        var nodes: [InlineNode] = []
        var literal = ""
        var index = input.startIndex

        func appendLiteral() -> Bool {
            guard !literal.isEmpty else { return true }
            guard nodes.count < limit else { return false }
            nodes.append(.text(literal))
            literal.removeAll(keepingCapacity: true)
            return true
        }

        while index < input.endIndex {
            let match: InlineMatch?
            if Self.isDelimiter("`", at: index, in: input) {
                match = Self.matchingDelimiter("`", from: index, in: input)
            } else if Self.isDelimiter("**", at: index, in: input) {
                match = Self.matchingDelimiter("**", from: index, in: input)
            } else if Self.isDelimiter("*", at: index, in: input) {
                match = Self.matchingDelimiter("*", from: index, in: input)
            } else {
                match = nil
            }

            guard let match else {
                literal.append(input[index])
                index = input.index(after: index)
                continue
            }
            guard appendLiteral(), nodes.count < limit else { return nil }
            switch match.delimiter {
            case "`": nodes.append(.inlineCode(match.content))
            case "**": nodes.append(.strong(match.content))
            default: nodes.append(.emphasis(match.content))
            }
            index = match.end
        }

        guard appendLiteral() else { return nil }
        return nodes
    }

    private static func matchingDelimiter(
        _ delimiter: String,
        from opening: String.Index,
        in input: String
    ) -> InlineMatch? {
        let contentStart = input.index(opening, offsetBy: delimiter.count)
        var candidate = contentStart
        while candidate < input.endIndex {
            guard let range = input.range(
                of: delimiter,
                range: candidate..<input.endIndex
            ) else {
                return nil
            }
            if isDelimiter(delimiter, at: range.lowerBound, in: input) {
                return InlineMatch(
                    delimiter: delimiter,
                    content: String(input[contentStart..<range.lowerBound]),
                    end: range.upperBound
                )
            }
            candidate = input.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isDelimiter(
        _ delimiter: String,
        at index: String.Index,
        in input: String
    ) -> Bool {
        guard input[index...].hasPrefix(delimiter) else { return false }
        let end = input.index(index, offsetBy: delimiter.count)
        let marker = delimiter.first
        let previousMatches = index > input.startIndex
            && input[input.index(before: index)] == marker
        let nextMatches = end < input.endIndex && input[end] == marker
        return !previousMatches && !nextMatches
    }

    private static func boundedPrefix(
        of input: String
    ) -> (value: String, truncated: Bool) {
        if input.utf8.count <= maximumInputBytes {
            return (input, false)
        }

        var byteCount = 0
        var end = input.startIndex
        while end < input.endIndex {
            let next = input.index(after: end)
            let characterBytes = input[end..<next].utf8.count
            guard byteCount + characterBytes <= maximumInputBytes else { break }
            byteCount += characterBytes
            end = next
        }
        return (String(input[..<end]), true)
    }

    private static func truncatedDocument(
        literalPrefix: String
    ) -> SafeMarkdownDocument {
        SafeMarkdownDocument(
            nodes: [
                .paragraph([.text(literalPrefix)]),
                .paragraph([.text(truncationNotice)])
            ],
            wasTruncated: true
        )
    }
}

private struct InlineMatch {
    let delimiter: String
    let content: String
    let end: String.Index
}
