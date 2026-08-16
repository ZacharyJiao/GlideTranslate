import Foundation

enum SafeMarkdownNode: Equatable, Sendable {
    case paragraph([InlineNode])
    case list([[InlineNode]])
}

enum InlineNode: Equatable, Sendable {
    case text(String)
    case emphasis(String)
    case strong(String)
    case inlineCode(String)
}

struct SafeMarkdownDocument: Equatable, Sendable {
    let nodes: [SafeMarkdownNode]
    let wasTruncated: Bool

    init(nodes: [SafeMarkdownNode], wasTruncated: Bool = false) {
        self.nodes = nodes
        self.wasTruncated = wasTruncated
    }

    var nodeCount: Int {
        nodes.reduce(into: 0) { count, node in
            count += 1
            switch node {
            case let .paragraph(inlines):
                count += inlines.count
            case let .list(items):
                count += items.count
                count += items.reduce(0) { $0 + $1.count }
            }
        }
    }
}
