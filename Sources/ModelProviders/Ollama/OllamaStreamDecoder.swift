import Foundation
import SharedSupport

private struct OllamaChatChunk: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message?
    let done: Bool
    let error: String?
}

struct OllamaStreamDecoder: Sendable {
    private static let maximumLineBytes = 1_048_576
    private static let maximumCumulativeContentBytes = 4_194_304

    private var buffer = Data()
    private var cumulativeContentBytes = 0
    private var isDone = false

    mutating func feed<Bytes: DataProtocol>(
        _ bytes: Bytes
    ) throws -> [TranslationChunk] {
        guard !isDone || bytes.isEmpty else { throw protocolFailure() }
        var output: [TranslationChunk] = []

        for byte in bytes {
            guard !isDone else { throw protocolFailure() }
            if byte == 0x0a {
                var line = buffer
                buffer.removeAll(keepingCapacity: true)
                if line.last == 0x0d { line.removeLast() }
                if line.isEmpty { continue }
                guard !isDone else { throw protocolFailure() }
                output += try decode(line)
            } else {
                guard buffer.count < Self.maximumLineBytes else {
                    throw protocolFailure()
                }
                buffer.append(byte)
            }
        }
        return output
    }

    mutating func finish() throws -> [TranslationChunk] {
        guard buffer.allSatisfy({ byte in
            byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x20
        }), isDone else {
            throw protocolFailure()
        }
        buffer.removeAll()
        return []
    }

    private func protocolFailure() -> SanitizedFailure {
        .providerProtocolFailure
    }

    private mutating func decode(_ line: Data) throws -> [TranslationChunk] {
        let chunk: OllamaChatChunk
        do {
            chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: line)
        } catch {
            throw protocolFailure()
        }
        guard chunk.error == nil else { throw protocolFailure() }
        var output: [TranslationChunk] = []
        if let content = chunk.message?.content, !content.isEmpty {
            let byteCount = content.utf8.count
            guard byteCount <= Self.maximumCumulativeContentBytes
                    - cumulativeContentBytes else {
                throw protocolFailure()
            }
            cumulativeContentBytes += byteCount
            output.append(.content(content))
        }
        if chunk.done {
            isDone = true
            output.append(.done)
        }
        return output
    }
}
