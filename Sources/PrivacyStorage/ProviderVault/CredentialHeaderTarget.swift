import Foundation

package protocol CredentialHeaderTarget {
    mutating func setAuthorizationCredential(
        _ credential: borrowing CredentialHeaderValue
    )
}

package struct CredentialHeaderValue: ~Copyable, Sendable {
    private var storage: Data

    package init(storage: consuming Data) {
        self.storage = storage
    }

    package borrowing func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }
}

package protocol ProviderCredentialLeaseObserving: Sendable {
    func destinationRevalidated()
    func leaseDestroyed()
}

package struct NoOpProviderCredentialLeaseObserver:
    ProviderCredentialLeaseObserving {
    package init() {}
    package func destinationRevalidated() {}
    package func leaseDestroyed() {}
}

package struct ProviderCredentialLease: ~Copyable, Sendable {
    private var credential: CredentialHeaderValue
    private let observer: any ProviderCredentialLeaseObserving

    package init(
        credential: consuming CredentialHeaderValue,
        observer: any ProviderCredentialLeaseObserving =
            NoOpProviderCredentialLeaseObserver()
    ) {
        self.credential = credential
        self.observer = observer
    }

    package borrowing func apply<T: CredentialHeaderTarget>(to target: inout T) {
        target.setAuthorizationCredential(credential)
    }

    deinit {
        observer.leaseDestroyed()
    }
}
