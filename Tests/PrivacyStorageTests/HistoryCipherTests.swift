import CryptoKit
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class HistoryCipherTests: XCTestCase {
    func testHistoryCipherUsesUniqueNonceAuthenticationAndRecordBoundAAD() throws {
        let cipher = HistoryCipher(
            key: SymmetricKey(data: Data((0..<32).map(UInt8.init)))
        )
        let id = TranslationRecordID(
            rawValue: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let payload = HistoryPayload.synthetic

        let first = try cipher.seal(payload, id: id)
        let second = try cipher.seal(payload, id: id)

        XCTAssertEqual(first.version, 1)
        XCTAssertNotEqual(first.sealedCombined, second.sealedCombined)
        XCTAssertEqual(try cipher.open(first, id: id), payload)

        var modified = first.sealedCombined
        modified[modified.count / 2] ^= 0x01
        XCTAssertThrowsError(try cipher.open(
            HistoryEnvelope(version: first.version, sealedCombined: modified),
            id: id
        )) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertThrowsError(try cipher.open(
            first,
            id: TranslationRecordID(
                rawValue: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
            )
        )) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertThrowsError(try cipher.open(
            HistoryEnvelope(version: 2, sealedCombined: first.sealedCombined),
            id: id
        )) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
    }

    func testHistoryPayloadContainsOnlyApprovedCompletionFields() throws {
        let payload = HistoryPayload.synthetic

        XCTAssertEqual(payload.sourceText, HistorySynthetic.source)
        XCTAssertEqual(payload.resultText, HistorySynthetic.result)
        XCTAssertEqual(payload.timestamp, HistorySynthetic.timestamp)
        XCTAssertEqual(payload.presetID, HistorySynthetic.presetID)
        XCTAssertEqual(payload.sourceLanguage, .automatic)
        XCTAssertEqual(
            payload.targetLanguage,
            .identified(HistorySynthetic.targetLanguage)
        )
        XCTAssertEqual(payload.providerClass, .cloud)

        let encoded = try PropertyListEncoder().encode(payload)
        let propertyList = try PropertyListSerialization.propertyList(
            from: encoded,
            format: nil
        )
        let fields = try XCTUnwrap(propertyList as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set([
            "sourceText",
            "resultText",
            "timestamp",
            "presetID",
            "sourceLanguage",
            "targetLanguage",
            "providerClass"
        ]))
    }

    func testProductionEnvelopeOpensWithTheExactStableAADAndBinaryPayload() throws {
        let keyData = Data((0..<32).map(UInt8.init))
        let key = SymmetricKey(data: keyData)
        let cipher = HistoryCipher(key: key)
        let id = TranslationRecordID(
            rawValue: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )

        let envelope = try cipher.seal(.synthetic, id: id)
        let box = try AES.GCM.SealedBox(combined: envelope.sealedCombined)
        var plaintext = try AES.GCM.open(
            box,
            using: key,
            authenticating: Data(
                "glidetranslate.history.v1:\(id.rawValue.uuidString)".utf8
            )
        )
        defer { plaintext.resetBytes(in: plaintext.indices) }

        XCTAssertEqual(
            try PropertyListDecoder().decode(HistoryPayload.self, from: plaintext),
            .synthetic
        )
        XCTAssertTrue(plaintext.starts(with: Data("bplist00".utf8)))
    }

    func testHistoryKeyStoreUsesIndependentExactIdentity() throws {
        let backing = CapturingHistorySymmetricKeyStore()
        let store = HistoryKeyStore(keyStore: backing)

        XCTAssertNil(try store.readKey())
        let created = try store.readOrCreateKey()
        try store.deleteKey()

        XCTAssertEqual(created.data.count, 32)
        XCTAssertTrue(created.createdByCaller)
        XCTAssertEqual(backing.operations, [
            .init(kind: .read, service: HistorySynthetic.historyKeyService, account: "v1"),
            .init(kind: .create, service: HistorySynthetic.historyKeyService, account: "v1"),
            .init(kind: .delete, service: HistorySynthetic.historyKeyService, account: "v1")
        ])
        XCTAssertNotEqual(
            HistorySynthetic.historyKeyService,
            "com.zaryolabs.GlideTranslate.private-presets-key"
        )
    }

    func testHistoryPayloadStringLimitsAreInclusiveAndRejectLimitPlusOne() throws {
        let cipher = HistoryCipher(
            key: SymmetricKey(data: Data((0..<32).map(UInt8.init)))
        )
        let id = TranslationRecordID()
        let exact = CompletedTranslation(
            requestID: TranslationRequestID(),
            sourceText: String(
                repeating: "s",
                count: PrivacyStorageResourceLimits.historySourceUTF8Bytes
            ),
            resultText: String(
                repeating: "r",
                count: PrivacyStorageResourceLimits.historyResultUTF8Bytes
            ),
            presetID: PresetID(rawValue: "bounded"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .cloud
        )
        XCTAssertNoThrow(try cipher.seal(
            HistoryPayload(completion: exact, timestamp: Date()),
            id: id
        ))

        let oversizedSource = CompletedTranslation(
            requestID: TranslationRequestID(),
            sourceText: String(
                repeating: "s",
                count: PrivacyStorageResourceLimits.historySourceUTF8Bytes + 1
            ),
            resultText: "result",
            presetID: PresetID(rawValue: "bounded"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .cloud
        )
        XCTAssertThrowsError(try cipher.seal(
            HistoryPayload(completion: oversizedSource, timestamp: Date()),
            id: id
        ))

        let oversizedResult = CompletedTranslation(
            requestID: TranslationRequestID(),
            sourceText: "source",
            resultText: String(
                repeating: "r",
                count: PrivacyStorageResourceLimits.historyResultUTF8Bytes + 1
            ),
            presetID: PresetID(rawValue: "bounded"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .cloud
        )
        XCTAssertThrowsError(try cipher.seal(
            HistoryPayload(completion: oversizedResult, timestamp: Date()),
            id: id
        ))
    }
}

extension HistoryPayload {
    static var synthetic: Self {
        Self(completion: HistorySynthetic.completion, timestamp: HistorySynthetic.timestamp)
    }
}

enum HistorySynthetic {
    static let source = ["T9", "-source-", "marker-", "alpha"].joined()
    static let result = ["T9", "-result-", "marker-", "beta"].joined()
    static let targetLanguage = ["x", "-history-", "target"].joined()
    static let presetID = PresetID(rawValue: [
        "custom", "-", "cccccccc", "-", "cccc", "-", "cccc", "-",
        "cccc", "-", "cccccccccccc"
    ].joined())
    static let timestamp = Date(timeIntervalSince1970: 1_777_777_777)
    static let historyKeyService = [
        "com.zaryolabs.GlideTranslate", ".history-key"
    ].joined()
    static let allHistoryMarkers = [source, result, targetLanguage, presetID.rawValue]
    static let completion = CompletedTranslation(
        requestID: TranslationRequestID(
            rawValue: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        ),
        sourceText: source,
        resultText: result,
        presetID: presetID,
        sourceLanguage: .automatic,
        targetLanguage: .identified(targetLanguage),
        providerClass: .cloud
    )
}

private struct HistoryKeyOperation: Equatable {
    enum Kind: Equatable { case read, create, delete }
    let kind: Kind
    let service: String
    let account: String
}

private final class CapturingHistorySymmetricKeyStore:
    SymmetricKeyStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HistoryKeyOperation] = []
    var operations: [HistoryKeyOperation] { lock.withLock { recorded } }

    func readKey(service: String, account: String) throws -> Data? {
        lock.withLock {
            recorded.append(.init(kind: .read, service: service, account: account))
        }
        return nil
    }

    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        lock.withLock {
            recorded.append(.init(kind: .create, service: service, account: account))
        }
        return SymmetricKeyMaterial(data: Data(repeating: 0x5a, count: 32), createdByCaller: true)
    }

    func deleteKey(service: String, account: String) throws {
        lock.withLock {
            recorded.append(.init(kind: .delete, service: service, account: account))
        }
    }
}
