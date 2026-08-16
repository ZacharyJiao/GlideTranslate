import Foundation

enum HTTPParserFailure: Error, Equatable, Sendable {
    case protocolViolation
}

package struct HTTPResponseHead: Equatable, Sendable {
    package let status: Int
    package let location: String?
}

package enum HTTPResponseEvent: Equatable, Sendable {
    case head(HTTPResponseHead)
    case body(Data)
    case complete
}

struct HTTPResponseParser: Sendable {
    private static let maximumHeaderBytes = 65_536
    private static let maximumInformationalResponses = 8
    private static let maximumDecodedEventBytes = 1_048_576
    private static let maximumCumulativeBodyBytes = 4_194_304
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let lineTerminator = Data([13, 10])

    private enum State: Sendable {
        case responseHead
        case fixedLength(remaining: Int)
        case closeDelimited
        case chunkSize
        case chunkBody(remaining: Int)
        case chunkBodyTerminator
        case trailers
        case complete
    }

    private var state: State = .responseHead
    private var buffer = Data()
    private var metadataBytes = 0
    private var informationalResponseCount = 0
    private var cumulativeBodyBytes = 0

    var isComplete: Bool {
        if case .complete = state { return true }
        return false
    }

    mutating func feed<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [HTTPResponseEvent] {
        guard !isComplete || bytes.isEmpty else {
            throw HTTPParserFailure.protocolViolation
        }

        var incoming = Data(bytes)
        var events: [HTTPResponseEvent] = []

        while !incoming.isEmpty {
            guard !isComplete else {
                throw HTTPParserFailure.protocolViolation
            }

            let count: Int
            if consumesMetadata {
                let available = Self.maximumHeaderBytes
                    - metadataBytes
                    - buffer.count
                guard available > 0 else {
                    throw HTTPParserFailure.protocolViolation
                }
                count = min(available, incoming.count)
            } else {
                switch state {
                case .fixedLength(let remaining), .chunkBody(let remaining):
                    count = min(remaining, incoming.count)
                default:
                    count = incoming.count
                }
            }
            buffer.append(incoming.prefix(count))
            incoming.removeFirst(count)
            events += try drainBuffer()
        }

        events += try drainBuffer()
        return events
    }

    private mutating func drainBuffer() throws -> [HTTPResponseEvent] {
        var events: [HTTPResponseEvent] = []

        while true {
            switch state {
            case .responseHead:
                guard let delimiter = buffer.range(of: Self.headerTerminator) else {
                    return events
                }

                let headLength = buffer.distance(
                    from: buffer.startIndex,
                    to: delimiter.upperBound
                )
                guard headLength <= Self.maximumHeaderBytes else {
                    throw HTTPParserFailure.protocolViolation
                }

                let headBytes = Data(buffer.prefix(headLength))
                try chargeMetadata(headLength)
                buffer.removeFirst(headLength)
                let parsed = try Self.parseResponseHead(headBytes)

                if (100..<200).contains(parsed.head.status) {
                    guard parsed.head.status != 101,
                          informationalResponseCount < Self.maximumInformationalResponses else {
                        throw HTTPParserFailure.protocolViolation
                    }
                    informationalResponseCount += 1
                    events.append(.head(parsed.head))
                    state = .responseHead
                    continue
                }

                events.append(.head(parsed.head))

                if parsed.head.status == 204 || parsed.head.status == 304 {
                    state = .complete
                    events.append(.complete)
                    continue
                }

                switch parsed.framing {
                case .chunked:
                    state = .chunkSize
                case .contentLength(let length):
                    if length == 0 {
                        state = .complete
                        events.append(.complete)
                    } else {
                        state = .fixedLength(remaining: length)
                    }
                case .closeDelimited:
                    state = .closeDelimited
                }

            case .fixedLength(let remaining):
                guard !buffer.isEmpty else { return events }
                let count = min(remaining, buffer.count)
                try validateBodyEvent(count: count)
                let body = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                cumulativeBodyBytes += count
                events.append(.body(body))

                let nextRemaining = remaining - count
                if nextRemaining == 0 {
                    state = .complete
                    events.append(.complete)
                } else {
                    state = .fixedLength(remaining: nextRemaining)
                }

            case .closeDelimited:
                guard !buffer.isEmpty else { return events }
                let count = buffer.count
                try validateBodyEvent(count: count)
                let body = buffer
                buffer.removeAll(keepingCapacity: true)
                cumulativeBodyBytes += count
                events.append(.body(body))

            case .chunkSize:
                guard let delimiter = buffer.range(of: Self.lineTerminator) else {
                    return events
                }

                let lineLength = buffer.distance(
                    from: buffer.startIndex,
                    to: delimiter.lowerBound
                )
                let consumedLength = buffer.distance(
                    from: buffer.startIndex,
                    to: delimiter.upperBound
                )
                let line = Data(buffer.prefix(lineLength))
                try chargeMetadata(consumedLength)
                buffer.removeFirst(consumedLength)
                let size = try Self.parseChunkSize(line)

                if size == 0 {
                    state = .trailers
                } else {
                    state = .chunkBody(remaining: size)
                }

            case .chunkBody(let remaining):
                guard !buffer.isEmpty else { return events }
                let count = min(remaining, buffer.count)
                try validateBodyEvent(count: count)
                let body = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                cumulativeBodyBytes += count
                events.append(.body(body))

                let nextRemaining = remaining - count
                if nextRemaining == 0 {
                    state = .chunkBodyTerminator
                } else {
                    state = .chunkBody(remaining: nextRemaining)
                }

            case .chunkBodyTerminator:
                guard buffer.count >= 2 else { return events }
                guard buffer.starts(with: Self.lineTerminator) else {
                    throw HTTPParserFailure.protocolViolation
                }
                try chargeMetadata(2)
                buffer.removeFirst(2)
                state = .chunkSize

            case .trailers:
                if buffer.starts(with: Self.lineTerminator) {
                    try chargeMetadata(2)
                    buffer.removeFirst(2)
                    state = .complete
                    events.append(.complete)
                    continue
                }

                guard let delimiter = buffer.range(of: Self.headerTerminator) else {
                    return events
                }
                let trailerLength = buffer.distance(
                    from: buffer.startIndex,
                    to: delimiter.upperBound
                )
                let trailerBytes = Data(buffer.prefix(trailerLength - 2))
                try Self.validateTrailerFields(trailerBytes)
                try chargeMetadata(trailerLength)
                buffer.removeFirst(trailerLength)
                state = .complete
                events.append(.complete)

            case .complete:
                guard buffer.isEmpty else {
                    throw HTTPParserFailure.protocolViolation
                }
                return events
            }
        }
    }

    mutating func finish() throws -> [HTTPResponseEvent] {
        switch state {
        case .closeDelimited:
            guard buffer.isEmpty else {
                throw HTTPParserFailure.protocolViolation
            }
            state = .complete
            return [.complete]
        case .complete:
            guard buffer.isEmpty else {
                throw HTTPParserFailure.protocolViolation
            }
            return []
        case .responseHead, .fixedLength, .chunkSize, .chunkBody,
             .chunkBodyTerminator, .trailers:
            throw HTTPParserFailure.protocolViolation
        }
    }

    private mutating func validateBodyEvent(count: Int) throws {
        guard count > 0,
              count <= Self.maximumDecodedEventBytes,
              cumulativeBodyBytes <= Self.maximumCumulativeBodyBytes - count else {
            throw HTTPParserFailure.protocolViolation
        }
    }

    private mutating func chargeMetadata(_ count: Int) throws {
        guard count > 0,
              metadataBytes <= Self.maximumHeaderBytes - count else {
            throw HTTPParserFailure.protocolViolation
        }
        metadataBytes += count
    }

    private var consumesMetadata: Bool {
        switch state {
        case .responseHead, .chunkSize, .chunkBodyTerminator, .trailers:
            return true
        case .fixedLength, .closeDelimited, .chunkBody, .complete:
            return false
        }
    }
}

private extension HTTPResponseParser {
    enum Framing {
        case contentLength(Int)
        case chunked
        case closeDelimited
    }

    struct ParsedHead {
        let head: HTTPResponseHead
        let framing: Framing
    }

    static func parseResponseHead(_ bytes: Data) throws -> ParsedHead {
        guard bytes.count >= headerTerminator.count,
              bytes.suffix(headerTerminator.count) == headerTerminator else {
            throw HTTPParserFailure.protocolViolation
        }

        // Retain the CRLF that terminates the final field so every parsed line
        // is checked with the same strict delimiter rule. Only the empty-line
        // CRLF is framing and is removed here.
        let fieldBytes = bytes.dropLast(lineTerminator.count)
        let lines = Data(fieldBytes).split(separator: 10)
        guard let rawStatusLine = lines.first else {
            throw HTTPParserFailure.protocolViolation
        }
        let statusLine = try decodeCRLFTerminatedLine(rawStatusLine, requiresCR: true)
        let status = try parseStatusLine(statusLine)

        var allValues: [String: [String]] = [:]
        for rawLine in lines.dropFirst() {
            let line = try decodeCRLFTerminatedLine(rawLine, requiresCR: true)
            let field = try parseHeaderField(line)
            allValues[field.name, default: []].append(field.value)
        }

        let transferValues = allValues["transfer-encoding"] ?? []
        let contentLengthValues = allValues["content-length"] ?? []
        guard transferValues.isEmpty || contentLengthValues.isEmpty else {
            throw HTTPParserFailure.protocolViolation
        }

        let framing: Framing
        if !transferValues.isEmpty {
            let codings = transferValues
                .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard codings == ["chunked"] else {
                throw HTTPParserFailure.protocolViolation
            }
            framing = .chunked
        } else if !contentLengthValues.isEmpty {
            let normalized = contentLengthValues.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = normalized.first,
                  normalized.allSatisfy({ $0 == first }),
                  !first.isEmpty,
                  first.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(first) else {
                throw HTTPParserFailure.protocolViolation
            }
            framing = .contentLength(length)
        } else {
            framing = .closeDelimited
        }

        let locations = allValues["location"] ?? []
        guard locations.count <= 1 else {
            throw HTTPParserFailure.protocolViolation
        }
        return ParsedHead(
            head: HTTPResponseHead(status: status, location: locations.first),
            framing: framing
        )
    }

    static func parseStatusLine(_ line: String) throws -> Int {
        guard line.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw HTTPParserFailure.protocolViolation
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0] == "HTTP/1.0" || parts[0] == "HTTP/1.1",
              parts[1].utf8.count == 3,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(parts[1]),
              (100...599).contains(status) else {
            throw HTTPParserFailure.protocolViolation
        }
        return status
    }

    static func decodeCRLFTerminatedLine(
        _ bytes: Data.SubSequence,
        requiresCR: Bool
    ) throws -> String {
        var bytes = Data(bytes)
        if requiresCR {
            guard bytes.last == 13 else {
                throw HTTPParserFailure.protocolViolation
            }
            bytes.removeLast()
        }
        guard bytes.allSatisfy({ $0 < 128 }) else {
            throw HTTPParserFailure.protocolViolation
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parseHeaderField(_ line: String) throws -> (name: String, value: String) {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
            throw HTTPParserFailure.protocolViolation
        }
        let name = String(line[..<colon]).lowercased()
        guard name.utf8.allSatisfy(isHeaderTokenByte) else {
            throw HTTPParserFailure.protocolViolation
        }
        let rawValue = line[line.index(after: colon)...]
        guard rawValue.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw HTTPParserFailure.protocolViolation
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, value)
    }

    static func isHeaderTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...122, 124, 126:
            return true
        default:
            return false
        }
    }

    static func parseChunkSize(_ line: Data) throws -> Int {
        guard line.allSatisfy({ (32...126).contains($0) }) else {
            throw HTTPParserFailure.protocolViolation
        }
        let sections = try splitChunkSizeLine(line)
        guard let sizeBytes = sections.first,
              !sizeBytes.isEmpty,
              sizeBytes.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }),
              sections.dropFirst().allSatisfy(validateChunkExtension),
              let sizeText = String(bytes: sizeBytes, encoding: .ascii),
              let size = UInt64(sizeText, radix: 16),
              size <= UInt64(Int.max) else {
            throw HTTPParserFailure.protocolViolation
        }
        return Int(size)
    }

    static func splitChunkSizeLine(_ line: Data) throws -> [Data] {
        var sections: [Data] = []
        var current = Data()
        var quoted = false
        var escaping = false

        for byte in line {
            if escaping {
                current.append(byte)
                escaping = false
                continue
            }
            if quoted, byte == 92 {
                current.append(byte)
                escaping = true
                continue
            }
            if byte == 34 {
                quoted.toggle()
                current.append(byte)
                continue
            }
            if byte == 59, !quoted {
                sections.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        guard !quoted, !escaping else {
            throw HTTPParserFailure.protocolViolation
        }
        sections.append(current)
        return sections
    }

    static func validateChunkExtension(_ bytes: Data.SubSequence) -> Bool {
        guard !bytes.isEmpty else { return false }
        let pieces = bytes.split(
            separator: 61,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let name = pieces.first,
              !name.isEmpty,
              name.allSatisfy(isHeaderTokenByte) else {
            return false
        }
        guard pieces.count == 2 else { return true }
        let value = pieces[1]
        guard !value.isEmpty else { return false }
        if value.first != 34 {
            return value.allSatisfy(isHeaderTokenByte)
        }
        guard value.count >= 2, value.last == 34 else { return false }
        let interior = value.dropFirst().dropLast()
        var escaping = false
        for byte in interior {
            guard (32...126).contains(byte) else { return false }
            if escaping {
                escaping = false
            } else if byte == 92 {
                escaping = true
            } else if byte == 34 {
                return false
            }
        }
        return !escaping
    }

    static func validateTrailerFields(_ bytes: Data) throws {
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        for rawLine in lines where !rawLine.isEmpty {
            let line = try decodeCRLFTerminatedLine(rawLine, requiresCR: true)
            _ = try parseHeaderField(line)
        }
    }
}
