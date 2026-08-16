import AppKit

@main
struct FocusFixtureApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = FocusFixtureAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class FocusFixtureAppDelegate: NSObject, NSApplicationDelegate,
    NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var textField: NSTextField!
    private var didEstablishFocus = false
    private var didLoseFocus = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = FocusFixtureWindowTitle.normal
        window.isReleasedWhenClosed = false
        window.delegate = self

        let textField = NSTextField(
            frame: NSRect(x: 40, y: 82, width: 280, height: 28)
        )
        textField.identifier = NSUserInterfaceItemIdentifier(
            "focus-fixture-field"
        )
        textField.stringValue = "focus stays here"
        textField.delegate = self
        window.contentView?.addSubview(textField)

        self.window = window
        self.textField = textField

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)
        DispatchQueue.main.async { [weak self] in
            self?.updateWindowTitleForFocus()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateWindowTitleForFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateWindowTitleForFocus()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        updateWindowTitleForFocus()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        updateWindowTitleForFocus()
    }

    private func updateWindowTitleForFocus() {
        let hasFocusedEditor = window.isKeyWindow &&
            window.firstResponder === textField.currentEditor()
        if hasFocusedEditor {
            didEstablishFocus = true
        } else if didEstablishFocus {
            didLoseFocus = true
        }

        if didLoseFocus {
            window.title = FocusFixtureWindowTitle.lost
        } else {
            window.title = hasFocusedEditor
                ? FocusFixtureWindowTitle.focused
                : FocusFixtureWindowTitle.normal
        }
    }
}

private enum FocusFixtureWindowTitle {
    static let normal = "Focus Fixture"
    static let focused = "Focus Fixture Focused"
    static let lost = "Focus Fixture Lost Focus"
}
