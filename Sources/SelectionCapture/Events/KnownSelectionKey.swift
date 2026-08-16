import AppKit

package enum KnownSelectionKey: Equatable, Sendable {
    case shiftLeft
    case shiftRight
    case shiftDown
    case shiftUp
    case optionShiftLeft
    case optionShiftRight
    case commandShiftLeft
    case commandShiftRight
    case shiftHome
    case shiftEnd

    package static func classify(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> KnownSelectionKey? {
        let relevant = flags.intersection([.shift, .option, .command, .control])
        guard relevant.contains(.shift), !relevant.contains(.control) else {
            return nil
        }
        switch keyCode {
        case 123 where relevant == [.shift]: return .shiftLeft
        case 124 where relevant == [.shift]: return .shiftRight
        case 125 where relevant == [.shift]: return .shiftDown
        case 126 where relevant == [.shift]: return .shiftUp
        case 123 where relevant == [.option, .shift]: return .optionShiftLeft
        case 124 where relevant == [.option, .shift]: return .optionShiftRight
        case 123 where relevant == [.command, .shift]: return .commandShiftLeft
        case 124 where relevant == [.command, .shift]: return .commandShiftRight
        case 115 where relevant == [.shift]: return .shiftHome
        case 119 where relevant == [.shift]: return .shiftEnd
        default: return nil
        }
    }
}
