import AppKit
import SharedSupport
import SwiftUI

struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var descriptor: ShortcutDescriptor
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(
            descriptor: descriptor,
            accessibilityLabel: localizedAccessibilityLabel
        ) { descriptor = $0 }
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.setDescriptor(descriptor)
        button.setAccessibilityLabel(localizedAccessibilityLabel)
    }

    private var localizedAccessibilityLabel: String {
        String(localized: "general.shortcut.recorder", locale: locale)
    }

    static func descriptor(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutDescriptor? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.option) { modifiers |= 0x0008_0000 }
        if flags.contains(.shift) { modifiers |= 0x0002_0000 }
        if flags.contains(.command) { modifiers |= 0x0010_0000 }
        if flags.contains(.control) { modifiers |= 0x0004_0000 }
        guard modifiers != 0 else { return nil }
        return ShortcutDescriptor(keyCode: UInt32(keyCode), modifiers: modifiers)
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    private var descriptor: ShortcutDescriptor
    private let onDescriptor: (ShortcutDescriptor) -> Void

    init(
        descriptor: ShortcutDescriptor,
        accessibilityLabel: String,
        onDescriptor: @escaping (ShortcutDescriptor) -> Void
    ) {
        self.descriptor = descriptor
        self.onDescriptor = onDescriptor
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
        setDescriptor(descriptor)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func setDescriptor(_ descriptor: ShortcutDescriptor) {
        self.descriptor = descriptor
        title = descriptor.displayLabel
        setAccessibilityValue(title)
    }

    @objc private func beginRecording() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let descriptor = ShortcutRecorderField.descriptor(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            NSSound.beep()
            return
        }
        setDescriptor(descriptor)
        onDescriptor(descriptor)
    }
}
