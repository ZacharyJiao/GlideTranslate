import Foundation
import SharedSupport

package struct DuplicateSuppressor: DuplicateSelectionChecking, Sendable {
    private struct Key: Equatable, Sendable {
        let text: String
        let application: ApplicationIdentity
    }

    private var previous: Key?
    private var reservations: [DuplicateReservation: Key] = [:]

    package init() {}

    package mutating func reserveIfNew(
        text: String,
        application: ApplicationIdentity
    ) -> DuplicateReservation? {
        let candidate = Key(text: text, application: application)
        guard candidate != previous,
              !reservations.values.contains(candidate) else {
            return nil
        }
        let reservation = DuplicateReservation(id: UUID())
        reservations[reservation] = candidate
        return reservation
    }

    package mutating func commit(_ reservation: DuplicateReservation) {
        guard let candidate = reservations.removeValue(forKey: reservation) else {
            return
        }
        previous = candidate
    }

    package mutating func cancel(_ reservation: DuplicateReservation) {
        reservations.removeValue(forKey: reservation)
    }

    package mutating func reset() {
        previous = nil
        reservations.removeAll(keepingCapacity: false)
    }
}
