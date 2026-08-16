import CryptoKit
import Foundation
import SharedSupport

package struct HistoryCipher: Sendable {
    private static let version: UInt16 = 1
    private let key: SymmetricKey

    package init(key: SymmetricKey) {
        self.key = key
    }

    package func seal(
        _ payload: HistoryPayload,
        id: TranslationRecordID
    ) throws -> HistoryEnvelope {
        let payload = try payload.validated()
        var plaintext: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            plaintext = try encoder.encode(payload)
        } catch {
            throw HistoryFailure.unrecoverable
        }
        defer { plaintext.resetBytes(in: plaintext.indices) }

        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: Self.aad(for: id)
            )
            guard let combined = box.combined else {
                throw HistoryFailure.unrecoverable
            }
            return HistoryEnvelope(
                version: Self.version,
                sealedCombined: combined
            )
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func open(
        _ envelope: HistoryEnvelope,
        id: TranslationRecordID
    ) throws -> HistoryPayload {
        let envelope = try envelope.validated(expectedVersion: Self.version)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedCombined)
            var plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: Self.aad(for: id)
            )
            defer { plaintext.resetBytes(in: plaintext.indices) }
            return try PropertyListDecoder().decode(
                HistoryPayload.self,
                from: plaintext
            ).validated()
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    private static func aad(for id: TranslationRecordID) -> Data {
        Data("glidetranslate.history.v1:\(id.rawValue.uuidString)".utf8)
    }
}

package struct HistoryKeyStore: Sendable {
    private static let account = "v1"
    private let keyStore: any SymmetricKeyStoring
    private let service: String

    package init(
        keyStore: any SymmetricKeyStoring = SymmetricKeyStore(),
        service: String = "com.zaryolabs.GlideTranslate.history-key"
    ) {
        self.keyStore = keyStore
        self.service = service
    }

    package func readKey() throws -> Data? {
        try keyStore.readKey(service: service, account: Self.account)
    }

    package func readOrCreateKey() throws -> SymmetricKeyMaterial {
        try keyStore.readOrCreateKey(service: service, account: Self.account)
    }

    package func deleteKey() throws {
        try keyStore.deleteKey(service: service, account: Self.account)
    }
}
