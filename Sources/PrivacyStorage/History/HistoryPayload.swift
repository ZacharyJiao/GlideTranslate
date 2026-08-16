import Foundation
import SharedSupport

package enum HistoryFailure: Error, Equatable, Sendable {
    case unrecoverable
}

package struct HistoryPayload: Codable, Equatable, Sendable {
    package let sourceText: String
    package let resultText: String
    package let timestamp: Date
    package let presetID: PresetID
    package let sourceLanguage: LanguageChoice
    package let targetLanguage: LanguageChoice
    package let providerClass: DestinationPrivacyClass

    package init(completion: CompletedTranslation, timestamp: Date) {
        sourceText = completion.sourceText
        resultText = completion.resultText
        self.timestamp = timestamp
        presetID = completion.presetID
        sourceLanguage = completion.sourceLanguage
        targetLanguage = completion.targetLanguage
        providerClass = completion.providerClass
    }

    package func validated() throws -> Self {
        guard sourceText.utf8.count
                <= PrivacyStorageResourceLimits.historySourceUTF8Bytes,
              resultText.utf8.count
                <= PrivacyStorageResourceLimits.historyResultUTF8Bytes,
              presetID.rawValue.utf8.count
                <= PrivacyStorageResourceLimits.historyPresetIdentifierUTF8Bytes else {
            throw HistoryFailure.unrecoverable
        }
        return self
    }
}

package struct HistoryEnvelope: Codable, Equatable, Sendable {
    package let version: UInt16
    package let sealedCombined: Data

    package init(version: UInt16, sealedCombined: Data) {
        self.version = version
        self.sealedCombined = sealedCombined
    }

    package func validated(expectedVersion: UInt16) throws -> Self {
        guard version == expectedVersion,
              !sealedCombined.isEmpty,
              sealedCombined.count <= PrivacyStorageResourceLimits
                .historyEnvelopeEncodedBytes else {
            throw HistoryFailure.unrecoverable
        }
        return self
    }
}
