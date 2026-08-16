import AppKit
import SharedSupport

package final class DefaultForegroundApplicationReader:
    ForegroundApplicationReading, @unchecked Sendable {
    private final class ActivationTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        private var observer: NSObjectProtocol?

        init() {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.lock.withLock { self?.value &+= 1 }
            }
        }

        deinit {
            if let observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }

        var sequence: UInt64 { lock.withLock { value } }
    }

    private let tracker: ActivationTracker

    package init() {
        tracker = ActivationTracker()
    }

    package func current() async
        -> Result<ForegroundApplicationContext, SelectionAuthorizationFailure> {
        await MainActor.run {
            guard let application = NSWorkspace.shared.frontmostApplication,
                  let bundleIdentifier = application.bundleIdentifier,
                  !bundleIdentifier.isEmpty else {
                return .failure(.unsupportedApplication)
            }
            let displayName = application.localizedName ?? bundleIdentifier
            return .success(ForegroundApplicationContext(
                application: ApplicationIdentity(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                ),
                processIdentifier: application.processIdentifier,
                activationSequence: tracker.sequence
            ))
        }
    }
}
