import Foundation
import SharedSupport

package protocol PasteboardReading: Sendable {
    var changeCount: Int { get }
    func stringForPlainText() -> String?
}

package protocol SecureInputReading: Sendable {
    var isEnabled: Bool { get }
}

package protocol CopyRequesting: Sendable {
    func requestCopy() throws
}

package protocol ShortcutClipboardReaderMaking: Sendable {
    func makeReader() -> any ShortcutClipboardReading
}

package actor LazyShortcutClipboardReader: ShortcutClipboardReading {
    private let factory: any ShortcutClipboardReaderMaking
    private var reader: (any ShortcutClipboardReading)?

    package init(factory: any ShortcutClipboardReaderMaking) {
        self.factory = factory
    }

    package func readShortcutSelection() async
        -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        let reader: any ShortcutClipboardReading
        if let existing = self.reader {
            reader = existing
        } else {
            let created = factory.makeReader()
            self.reader = created
            reader = created
        }
        return await reader.readShortcutSelection()
    }
}

package actor ClipboardSelectionReader: ShortcutClipboardReading {
    private let pasteboard: any PasteboardReading
    private let secureInput: any SecureInputReading
    private let copyRequester: any CopyRequesting
    private let filter: SelectionFilter
    private let clock: any AppClock
    private var readInProgress = false

    package init(
        pasteboard: any PasteboardReading,
        secureInput: any SecureInputReading,
        copyRequester: any CopyRequesting,
        filter: SelectionFilter,
        clock: any AppClock
    ) {
        self.pasteboard = pasteboard
        self.secureInput = secureInput
        self.copyRequester = copyRequester
        self.filter = filter
        self.clock = clock
    }

    package func readShortcutSelection() async
        -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        guard !readInProgress else { return .failure(.unsafeFallbackState) }
        readInProgress = true
        defer { readInProgress = false }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let initiallySecure = await secureInputEnabled()
        guard !initiallySecure else {
            return .failure(.unsafeFallbackState)
        }

        let baselineChangeCount = await pasteboardChangeCount()
        let secureBeforeCopy = await secureInputEnabled()
        guard !secureBeforeCopy else {
            return .failure(.unsafeFallbackState)
        }
        do {
            let requester = copyRequester
            try await MainActor.run { try requester.requestCopy() }
        } catch {
            return .failure(.unsafeFallbackState)
        }

        var observedChange = false
        for _ in 0..<20 {
            do {
                try await clock.sleep(for: .milliseconds(25))
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.unsafeFallbackState)
            }
            guard !Task.isCancelled else { return .failure(.cancelled) }
            let secureDuringWait = await secureInputEnabled()
            guard !secureDuringWait else {
                return .failure(.unsafeFallbackState)
            }
            if await pasteboardChangeCount() != baselineChangeCount {
                observedChange = true
                break
            }
        }

        let copiedChangeCount = await pasteboardChangeCount()
        guard observedChange, copiedChangeCount != baselineChangeCount else {
            return .failure(.noValidSelection)
        }
        guard let copied = await copiedPlainText() else {
            return .failure(.noValidSelection)
        }
        switch filter.apply(copied) {
        case .success(let text):
            return .success(CapturedSelection(text: text, displayRect: nil))
        case .failure:
            return .failure(.noValidSelection)
        }
    }

    private func secureInputEnabled() async -> Bool {
        let secureInput = self.secureInput
        return await MainActor.run { secureInput.isEnabled }
    }

    private func pasteboardChangeCount() async -> Int {
        let pasteboard = self.pasteboard
        return await MainActor.run { pasteboard.changeCount }
    }

    private func copiedPlainText() async -> String? {
        let pasteboard = self.pasteboard
        return await MainActor.run { pasteboard.stringForPlainText() }
    }
}
