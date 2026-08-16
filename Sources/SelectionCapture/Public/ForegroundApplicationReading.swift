import Darwin
import SharedSupport

public struct ForegroundApplicationContext: Equatable, Sendable {
    public let application: ApplicationIdentity
    package let processIdentifier: pid_t
    package let activationSequence: UInt64

    package init(
        application: ApplicationIdentity,
        processIdentifier: pid_t,
        activationSequence: UInt64
    ) {
        self.application = application
        self.processIdentifier = processIdentifier
        self.activationSequence = activationSequence
    }
}

public protocol ForegroundApplicationReading: Sendable {
    func current() async
        -> Result<ForegroundApplicationContext, SelectionAuthorizationFailure>
}
