import Foundation
import SharedSupport

package struct DecryptedHistoryRow: Sendable {
    package let id: TranslationRecordID
    package let value: HistoryPayload
    private let lifetime: DecryptedHistoryLifetime?

    package init(
        id: TranslationRecordID,
        value: HistoryPayload,
        onRelease: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.value = value
        lifetime = onRelease.map(DecryptedHistoryLifetime.init)
    }
}

private final class DecryptedHistoryLifetime: @unchecked Sendable {
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

package struct HistoryRetentionValue: Sendable {
    package let id: TranslationRecordID
    package let timestamp: Date
}

package enum HistoryRetention {
    package static func deletionIDs(
        from values: [HistoryRetentionValue],
        now: Date,
        retentionDays: Int,
        maximumCount: Int
    ) -> [TranslationRecordID] {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(retentionDays) * 24 * 60 * 60
        )
        var deletion = Set(
            values.lazy.filter { $0.timestamp < cutoff }.map(\.id)
        )
        let retained = values
            .filter { !deletion.contains($0.id) }
            .sorted(by: newestFirst)
        if retained.count > maximumCount {
            deletion.formUnion(retained.dropFirst(maximumCount).map(\.id))
        }
        return deletion.sorted {
            databaseID($0) < databaseID($1)
        }
    }

    package static func newestFirst(
        _ lhs: HistoryRetentionValue,
        _ rhs: HistoryRetentionValue
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        return databaseID(lhs.id) < databaseID(rhs.id)
    }

    package static func databaseID(_ id: TranslationRecordID) -> String {
        id.rawValue.uuidString.lowercased()
    }
}
