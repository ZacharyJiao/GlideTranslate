import Observation
import SelectionCapture
import SharedSupport

enum ShortcutRegistrationState: Equatable, Sendable {
    case unregistered
    case registered
    case replacementRequired
    case unavailable
}

@MainActor
@Observable
final class ShortcutSettingsModel {
    private let registrar: any GlobalShortcutRegistering
    private(set) var currentDescriptor: ShortcutDescriptor?
    private(set) var state: ShortcutRegistrationState
    private(set) var safeNextActionKey: String?

    init(
        registrar: any GlobalShortcutRegistering,
        currentDescriptor: ShortcutDescriptor? = nil
    ) {
        self.registrar = registrar
        self.currentDescriptor = currentDescriptor
        state = currentDescriptor == nil ? .unregistered : .registered
    }

    var currentLabel: String {
        currentDescriptor?.displayLabel ?? "—"
    }

    var requiresReplacement: Bool { state == .replacementRequired }

    // C5 owns Carbon registration. The UI model intentionally has no event-monitor seam.
    var keyloggerInstallCount: Int { 0 }
    var manualOpenCount: Int { 0 }

    func register(_ descriptor: ShortcutDescriptor) async {
        let previous = currentDescriptor
        do {
            try await registrar.register(descriptor)
            currentDescriptor = descriptor
            state = .registered
            safeNextActionKey = nil
        } catch ShortcutRegistrationFailure.conflict {
            let restored = await restore(previous)
            currentDescriptor = restored ? previous : nil
            state = restored || previous == nil ? .replacementRequired : .unavailable
            safeNextActionKey = restored || previous == nil
                ? "shortcut.conflict.nextAction"
                : "shortcut.unavailable.nextAction"
        } catch {
            let restored = await restore(previous)
            currentDescriptor = restored ? previous : nil
            state = .unavailable
            safeNextActionKey = "shortcut.unavailable.nextAction"
        }
    }

    /// Registers the persisted descriptor for a fresh process. Unlike an edit,
    /// there is no previously installed registration to restore on failure.
    func registerInitial(_ descriptor: ShortcutDescriptor) async {
        do {
            try await registrar.register(descriptor)
            currentDescriptor = descriptor
            state = .registered
            safeNextActionKey = nil
        } catch ShortcutRegistrationFailure.conflict {
            currentDescriptor = nil
            state = .replacementRequired
            safeNextActionKey = "shortcut.conflict.nextAction"
        } catch {
            currentDescriptor = nil
            state = .unavailable
            safeNextActionKey = "shortcut.unavailable.nextAction"
        }
    }

    private func restore(_ descriptor: ShortcutDescriptor?) async -> Bool {
        guard let descriptor else { return true }
        do {
            try await registrar.register(descriptor)
            return true
        } catch {
            return false
        }
    }
}

extension ShortcutDescriptor {
    var displayLabel: String {
        var label = ""
        if modifiers & 0x0008_0000 != 0 { label += "⌥" }
        if modifiers & 0x0002_0000 != 0 { label += "⇧" }
        if modifiers & 0x0010_0000 != 0 { label += "⌘" }
        if modifiers & 0x0004_0000 != 0 { label += "⌃" }
        label += Self.keyLabels[keyCode] ?? "Key \(keyCode)"
        return label
    }

    static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    ]
}
