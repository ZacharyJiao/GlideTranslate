import AppKit
@preconcurrency import ApplicationServices

@MainActor
struct SystemOnboardingClipboard: OnboardingClipboardWriting {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
struct SystemAccessibilityPrompt: AccessibilityPrompting {
    func requestSelectionAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
