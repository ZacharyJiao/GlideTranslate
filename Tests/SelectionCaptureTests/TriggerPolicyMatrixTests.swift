import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class TriggerPolicyMatrixTests: XCTestCase {
    private let app = ApplicationIdentity(
        bundleIdentifier: "invalid.example.fixture",
        displayName: "Fixture"
    )

    private struct Row {
        let name: String
        let trigger: CaptureTrigger
        let master: Bool
        let mouseEnabled: Bool
        let keyboardEnabled: Bool
        let generalAllowed: Bool
        let offDeviceAllowed: Bool
        let privacyClass: DestinationPrivacyClass
        let clipboardEnabled: Bool
        let expected: PreReadDecision
    }

    func testAutomaticCaptureAcceptsLocalizedRuntimeNameForConfiguredBundle() {
        let configured = ApplicationIdentity(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "TextEdit"
        )
        let running = ApplicationIdentity(
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "文本编辑"
        )
        let policy = CapturePolicySnapshot.fixture(
            master: true,
            mouseEnabled: true,
            keyboardEnabled: false,
            general: [configured],
            offDevice: [],
            clipboard: false
        )

        XCTAssertEqual(
            PreReadPolicy.evaluate(
                trigger: .mouse,
                application: running,
                policy: policy,
                privacyClass: .localOnDevice
            ),
            .accessibility
        )
    }

    func testCompleteTriggerMatrix() {
        let mouseDisabled = CapturePolicySnapshot.fixture(
            master: true,
            mouseEnabled: false,
            keyboardEnabled: false,
            general: [app],
            offDevice: [app],
            clipboard: false
        )
        XCTAssertEqual(
            PreReadPolicy.evaluate(
                trigger: .mouse,
                application: app,
                policy: mouseDisabled,
                privacyClass: .localOnDevice
            ),
            .rejected(.mouseCaptureDisabled),
            "mouse disabled"
        )

        let rows: [Row] = [
            .init(name: "mouse paused", trigger: .mouse, master: false,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .localOnDevice, clipboardEnabled: false,
                  expected: .rejected(.automaticCapturePaused)),
            .init(name: "mouse app denied", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: true,
                  privacyClass: .localOnDevice, clipboardEnabled: false,
                  expected: .rejected(.applicationNotAllowed)),
            .init(name: "mouse local", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: false,
                  privacyClass: .localOnDevice, clipboardEnabled: false,
                  expected: .accessibility),
            .init(name: "mouse network denied", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: false,
                  privacyClass: .localNetwork, clipboardEnabled: false,
                  expected: .rejected(.offDeviceApplicationNotAllowed)),
            .init(name: "mouse network allowed", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .localNetwork, clipboardEnabled: true,
                  expected: .accessibility),
            .init(name: "mouse cloud denied", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: false,
                  privacyClass: .cloud, clipboardEnabled: false,
                  expected: .rejected(.offDeviceApplicationNotAllowed)),
            .init(name: "mouse cloud allowed", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .cloud, clipboardEnabled: false,
                  expected: .accessibility),
            .init(name: "mouse unresolved", trigger: .mouse, master: true,
                  mouseEnabled: true, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .unresolvedOrChanged, clipboardEnabled: false,
                  expected: .rejected(.providerDestinationUnresolved)),
            .init(name: "keyboard disabled", trigger: .keyboardSelection, master: true,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .localOnDevice, clipboardEnabled: false,
                  expected: .rejected(.keyboardCaptureDisabled)),
            .init(name: "keyboard paused", trigger: .keyboardSelection, master: false,
                  mouseEnabled: false, keyboardEnabled: true,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .localOnDevice, clipboardEnabled: false,
                  expected: .rejected(.automaticCapturePaused)),
            .init(name: "keyboard cloud allowed", trigger: .keyboardSelection, master: true,
                  mouseEnabled: false, keyboardEnabled: true,
                  generalAllowed: true, offDeviceAllowed: true,
                  privacyClass: .cloud, clipboardEnabled: false,
                  expected: .accessibility),
            .init(name: "shortcut explicit cloud", trigger: .shortcut, master: false,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: false,
                  privacyClass: .cloud, clipboardEnabled: false,
                  expected: .accessibility),
            .init(name: "shortcut clipboard enabled", trigger: .shortcut, master: false,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: false,
                  privacyClass: .localOnDevice, clipboardEnabled: true,
                  expected: .accessibilityWithOptionalClipboard),
            .init(name: "shortcut unresolved", trigger: .shortcut, master: false,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: false,
                  privacyClass: .unresolvedOrChanged, clipboardEnabled: true,
                  expected: .rejected(.providerDestinationUnresolved)),
            .init(name: "manual explicit network", trigger: .manualInput, master: false,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: false,
                  privacyClass: .localNetwork, clipboardEnabled: false,
                  expected: .manual),
            .init(name: "manual unresolved", trigger: .manualInput, master: false,
                  mouseEnabled: false, keyboardEnabled: false,
                  generalAllowed: false, offDeviceAllowed: false,
                  privacyClass: .unresolvedOrChanged, clipboardEnabled: false,
                  expected: .rejected(.providerDestinationUnresolved))
        ]

        for row in rows {
            let policy = CapturePolicySnapshot.fixture(
                master: row.master,
                mouseEnabled: row.mouseEnabled,
                keyboardEnabled: row.keyboardEnabled,
                general: row.generalAllowed ? [app] : [],
                offDevice: row.offDeviceAllowed ? [app] : [],
                clipboard: row.clipboardEnabled
            )
            XCTAssertEqual(
                PreReadPolicy.evaluate(
                    trigger: row.trigger,
                    application: app,
                    policy: policy,
                    privacyClass: row.privacyClass
                ),
                row.expected,
                row.name
            )
        }
    }
}
