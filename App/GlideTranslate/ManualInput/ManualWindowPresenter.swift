import Foundation
import Observation
import SharedSupport

@MainActor
@Observable
final class ManualWindowPresenter: ManualInputPresenting {
    static let sceneID = "manual-input"

    private(set) var requestCount = 0
    private(set) var consumedRequestCount = 0
    private(set) var requestedPresetID: PresetID?
    private(set) var presetPickerSessionID: UUID?
    private var presetSelection: (@MainActor @Sendable (PresetID) -> Void)?

    var requestedSceneIDs: [String] {
        Array(repeating: Self.sceneID, count: requestCount)
    }

    func open() {
        requestCount &+= 1
    }

    func openPendingRequests(
        using openWindow: @MainActor (String) -> Void,
        activateApplication: @MainActor () -> Void
    ) {
        guard consumedRequestCount < requestCount else { return }
        consumedRequestCount = requestCount
        openWindow(Self.sceneID)
        activateApplication()
    }

    func openPresetPicker(
        sessionID: UUID,
        currentPresetID: PresetID,
        onSelect: @escaping @MainActor @Sendable (PresetID) -> Void
    ) {
        presetPickerSessionID = sessionID
        requestedPresetID = currentPresetID
        presetSelection = onSelect
        open()
    }

    func selectPreset(_ presetID: PresetID) {
        presetSelection?(presetID)
        presetSelection = nil
        requestedPresetID = nil
        presetPickerSessionID = nil
    }

    func cancelPresetPicker(sessionID: UUID?) {
        if let sessionID, presetPickerSessionID != sessionID { return }
        presetSelection = nil
        requestedPresetID = nil
        presetPickerSessionID = nil
    }
}
