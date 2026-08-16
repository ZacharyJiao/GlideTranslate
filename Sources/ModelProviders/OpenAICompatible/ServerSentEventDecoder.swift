import Foundation
import SharedSupport

private struct ChatCompletionsChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]?
}

struct ServerSentEventDecoder: Sendable {
    private static let maximumEventBytes = 1_048_576
    private static let maximumDataLinePrefixBytes = Data("data: ".utf8).count
    private static let maximumLineBytes = maximumEventBytes
        + maximumDataLinePrefixBytes
        + 1 // Optional CR retained until LF is consumed.
    private static let maximumCumulativeContentBytes = 4_194_304
    private static let done = Data("[DONE]".utf8)

    private var lineBuffer = Data()
    private var dataFields: [Data] = []
    private var dataFieldBytes = 0
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
                var line = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                if line.last == 0x0d { line.removeLast() }
                output += try consume(line)
            } else {
                guard lineBuffer.count < Self.maximumLineBytes else {
                    throw protocolFailure()
                }
                lineBuffer.append(byte)
            }
        }
        return output
    }

    mutating func finish() throws -> [TranslationChunk] {
        guard isDone, lineBuffer.isEmpty, dataFields.isEmpty else {
            throw protocolFailure()
        }
        return []
    }

    private mutating func consume(_ line: Data) throws -> [TranslationChunk] {
        if line.isEmpty { return try dispatch() }
        if line.first == 0x3a { return [] }

        let separator = line.firstIndex(of: 0x3a)
        let field = separator.map { line[..<$0] } ?? line[...]
        guard field.elementsEqual(Data("data".utf8)) else { return [] }
        var value = separator.map { Data(line[line.index(after: $0)...]) } ?? Data()
        if value.first == 0x20 { value.removeFirst() }
        let joinByte = dataFields.isEmpty ? 0 : 1
        let (bytesWithJoin, joinOverflow) = dataFieldBytes.addingReportingOverflow(
            joinByte
        )
        let (newByteCount, valueOverflow) = bytesWithJoin.addingReportingOverflow(
            value.count
        )
        guard !joinOverflow, !valueOverflow,
              newByteCount <= Self.maximumEventBytes else {
            throw protocolFailure()
        }
        dataFields.append(value)
        dataFieldBytes = newByteCount
        return []
    }

    private mutating func dispatch() throws -> [TranslationChunk] {
        guard !dataFields.isEmpty else { return [] }
        var payload = Data()
        payload.reserveCapacity(dataFieldBytes)
        for (index, field) in dataFields.enumerated() {
            if index > 0 { payload.append(0x0a) }
            payload.append(field)
        }
        dataFields.removeAll(keepingCapacity: true)
        dataFieldBytes = 0

        if payload == Self.done {
            isDone = true
            return [.done]
        }
        let chunk: ChatCompletionsChunk
        do {
            chunk = try JSONDecoder().decode(ChatCompletionsChunk.self, from: payload)
        } catch {
            throw protocolFailure()
        }
        guard let choices = chunk.choices, !choices.isEmpty else {
            throw protocolFailure()
        }
        var output: [TranslationChunk] = []
        for content in choices.compactMap(\.delta.content).filter({ !$0.isEmpty }) {
            let count = content.utf8.count
            let (newByteCount, overflow) = cumulativeContentBytes
                .addingReportingOverflow(count)
            guard !overflow,
                  newByteCount <= Self.maximumCumulativeContentBytes else {
                throw protocolFailure()
            }
            cumulativeContentBytes = newByteCount
            output.append(.content(content))
        }
        return output
    }

    private func protocolFailure() -> SanitizedFailure {
        .providerProtocolFailure
    }
}
