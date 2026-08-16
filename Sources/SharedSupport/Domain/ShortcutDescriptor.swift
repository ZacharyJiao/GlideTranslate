public struct ShortcutDescriptor: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultOptionShiftD = Self(
        keyCode: 2,
        modifiers: 0x0008_0000 | 0x0002_0000
    )
}
