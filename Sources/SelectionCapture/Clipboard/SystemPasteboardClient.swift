import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SharedSupport

package struct SystemPasteboardClient: PasteboardReading, @unchecked Sendable {
    package init() {}

    package var changeCount: Int { NSPasteboard.general.changeCount }

    package func stringForPlainText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

package struct SystemSecureInputReader: SecureInputReading, Sendable {
    package init() {}
    package var isEnabled: Bool { IsSecureEventInputEnabled() }
}

package enum CopyRequestFailure: Error, Equatable, Sendable {
    case eventUnavailable
}

package enum CommandCopyEventPhase: Equatable, Sendable {
    case keyDown
    case keyUp
}

package struct CommandCopyEventDescriptor: Equatable, Sendable {
    package let virtualKey: UInt16
    package let commandModified: Bool
    package let phase: CommandCopyEventPhase
}

package struct CommandCopyEventToken: @unchecked Sendable {
    fileprivate let event: CGEvent?
    package static func fixture() -> Self { Self(event: nil) }
}

package struct CommandCopySequence: Sendable {
    fileprivate let keyDown: CommandCopyEventToken
    fileprivate let keyUp: CommandCopyEventToken

    package static func fixture() -> Self {
        Self(keyDown: .fixture(), keyUp: .fixture())
    }
}

package protocol CommandCopyEventBuilding: Sendable {
    func makeEvent(
        _ descriptor: CommandCopyEventDescriptor
    ) throws -> CommandCopyEventToken
}

package protocol CommandCopySequencePosting: Sendable {
    func post(_ sequence: CommandCopySequence)
}

package struct SystemCopyRequester: CopyRequesting, Sendable {
    private let eventBuilder: any CommandCopyEventBuilding
    private let sequencePoster: any CommandCopySequencePosting

    package init(
        eventBuilder: any CommandCopyEventBuilding = SystemCommandCopyEventBuilder(),
        sequencePoster: any CommandCopySequencePosting = SystemCommandCopySequencePoster()
    ) {
        self.eventBuilder = eventBuilder
        self.sequencePoster = sequencePoster
    }

    package func requestCopy() throws {
        let virtualKey = UInt16(kVK_ANSI_C)
        let keyDown = try eventBuilder.makeEvent(.init(
            virtualKey: virtualKey,
            commandModified: true,
            phase: .keyDown
        ))
        let keyUp = try eventBuilder.makeEvent(.init(
            virtualKey: virtualKey,
            commandModified: true,
            phase: .keyUp
        ))
        sequencePoster.post(CommandCopySequence(
            keyDown: keyDown,
            keyUp: keyUp
        ))
    }
}

private struct SystemCommandCopyEventBuilder:
    CommandCopyEventBuilding, Sendable {
    func makeEvent(
        _ descriptor: CommandCopyEventDescriptor
    ) throws -> CommandCopyEventToken {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(descriptor.virtualKey),
                keyDown: descriptor.phase == .keyDown
              ) else {
            throw CopyRequestFailure.eventUnavailable
        }
        event.flags = descriptor.commandModified ? .maskCommand : []
        return CommandCopyEventToken(event: event)
    }
}

private struct SystemCommandCopySequencePoster:
    CommandCopySequencePosting, Sendable {
    func post(_ sequence: CommandCopySequence) {
        sequence.keyDown.event?.post(tap: .cghidEventTap)
        sequence.keyUp.event?.post(tap: .cghidEventTap)
    }
}

package struct SystemShortcutClipboardReaderFactory:
    ShortcutClipboardReaderMaking, Sendable {
    private let clock: any AppClock

    package init(clock: any AppClock) { self.clock = clock }

    package func makeReader() -> any ShortcutClipboardReading {
        ClipboardSelectionReader(
            pasteboard: SystemPasteboardClient(),
            secureInput: SystemSecureInputReader(),
            copyRequester: SystemCopyRequester(),
            filter: SelectionFilter(limit: 2_000),
            clock: clock
        )
    }
}
