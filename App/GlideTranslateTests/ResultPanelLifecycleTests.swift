import AppKit
import CoreGraphics
import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class ResultPanelLifecycleTests: XCTestCase {
    private enum PanelLifecycleRow {
        case showTemporary(count: Int, pinnedCount: Int)
        case replaceTemporary(count: Int, oldClosed: Bool)
        case pinTemporary(temporaryCount: Int, pinnedCount: Int)
        case newTemporaryWhilePinned(temporaryCount: Int, pinnedCount: Int)
        case pinSecond(replacesPinned: Bool, noticeCount: Int)
        case escapeTemporary(closed: Bool, pinnedClosed: Bool)
        case clickAwayTemporary(closed: Bool, pinnedClosed: Bool)
        case explicitClosePinned(pinnedCount: Int)
        case newSelectionReplacesTemporaryOnly
    }

    private let rows: [PanelLifecycleRow] = [
        .showTemporary(count: 1, pinnedCount: 0),
        .replaceTemporary(count: 1, oldClosed: true),
        .pinTemporary(temporaryCount: 0, pinnedCount: 1),
        .newTemporaryWhilePinned(temporaryCount: 1, pinnedCount: 1),
        .pinSecond(replacesPinned: true, noticeCount: 1),
        .escapeTemporary(closed: true, pinnedClosed: false),
        .clickAwayTemporary(closed: true, pinnedClosed: false),
        .explicitClosePinned(pinnedCount: 0),
        .newSelectionReplacesTemporaryOnly
    ]

    func testCompleteLifecycleTable() {
        for row in rows {
            let controller = ResultPanelController(configuration: .testing)

            switch row {
            case let .showTemporary(count, pinnedCount):
                controller.showTemporary(presentation("first"), actions: actions)
                XCTAssertEqual(controller.debugSnapshot.temporaryCount, count)
                XCTAssertEqual(controller.debugSnapshot.pinnedCount, pinnedCount)

            case let .replaceTemporary(count, oldClosed):
                controller.showTemporary(presentation("old"), actions: actions)
                let old = controller.debugTemporaryPanel
                controller.showTemporary(presentation("new"), actions: actions)
                XCTAssertEqual(controller.debugSnapshot.temporaryCount, count)
                XCTAssertEqual(old?.didClose, oldClosed)

            case let .pinTemporary(temporaryCount, pinnedCount):
                controller.showTemporary(presentation("first"), actions: actions)
                controller.pinTemporary()
                XCTAssertEqual(controller.debugSnapshot.temporaryCount, temporaryCount)
                XCTAssertEqual(controller.debugSnapshot.pinnedCount, pinnedCount)

            case let .newTemporaryWhilePinned(temporaryCount, pinnedCount):
                controller.showTemporary(presentation("pin"), actions: actions)
                controller.pinTemporary()
                let pinned = controller.debugPinnedPanel
                controller.showTemporary(presentation("temporary"), actions: actions)
                XCTAssertEqual(controller.debugSnapshot.temporaryCount, temporaryCount)
                XCTAssertEqual(controller.debugSnapshot.pinnedCount, pinnedCount)
                XCTAssertTrue(controller.debugPinnedPanel === pinned)

            case let .pinSecond(replacesPinned, noticeCount):
                controller.showTemporary(presentation("first"), actions: actions)
                controller.pinTemporary()
                let oldPinned = controller.debugPinnedPanel
                controller.showTemporary(presentation("second"), actions: actions)
                controller.pinTemporary()
                XCTAssertEqual(oldPinned?.didClose, replacesPinned)
                XCTAssertEqual(controller.debugSnapshot.noticeCount, noticeCount)
                XCTAssertEqual(controller.debugSnapshot.pinnedCount, 1)

            case let .escapeTemporary(closed, pinnedClosed):
                controller.showTemporary(presentation("pin"), actions: actions)
                controller.pinTemporary()
                let pinned = controller.debugPinnedPanel
                controller.showTemporary(presentation("temporary"), actions: actions)
                let temporary = controller.debugTemporaryPanel
                controller.debugBeginTemporaryInteraction()
                XCTAssertTrue(controller.debugSnapshot.escapeMonitorInstalled)
                controller.debugPressEscape()
                XCTAssertEqual(temporary?.didClose, closed)
                XCTAssertEqual(pinned?.didClose, pinnedClosed)
                XCTAssertFalse(controller.debugSnapshot.escapeMonitorInstalled)

            case let .clickAwayTemporary(closed, pinnedClosed):
                controller.showTemporary(presentation("pin"), actions: actions)
                controller.pinTemporary()
                let pinned = controller.debugPinnedPanel
                controller.showTemporary(presentation("temporary"), actions: actions)
                let temporary = controller.debugTemporaryPanel
                controller.debugClickAway()
                XCTAssertEqual(temporary?.didClose, closed)
                XCTAssertEqual(pinned?.didClose, pinnedClosed)
                XCTAssertFalse(controller.debugSnapshot.clickAwayMonitorInstalled)

            case let .explicitClosePinned(pinnedCount):
                controller.showTemporary(presentation("pin"), actions: actions)
                controller.pinTemporary()
                controller.dismissPinned()
                XCTAssertEqual(controller.debugSnapshot.pinnedCount, pinnedCount)

            case .newSelectionReplacesTemporaryOnly:
                controller.showTemporary(presentation("pin"), actions: actions)
                controller.pinTemporary()
                let pinned = controller.debugPinnedPanel
                controller.showTemporary(presentation("old"), actions: actions)
                let oldTemporary = controller.debugTemporaryPanel
                controller.showTemporary(presentation("new"), actions: actions)
                XCTAssertTrue(oldTemporary?.didClose == true)
                XCTAssertTrue(controller.debugPinnedPanel === pinned)
                XCTAssertFalse(pinned?.didClose == true)
            }
        }
    }

    func testPassivePanelFlagsAndStreamingUpdateDoNotReorder() throws {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(presentation("first"), actions: actions)
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(controller.debugSnapshot.passiveOrderCount, 1)

        controller.updateTemporary(presentation("updated"))
        XCTAssertTrue(controller.debugTemporaryPanel === panel)
        XCTAssertEqual(controller.debugSnapshot.passiveOrderCount, 1)

        controller.debugBeginTemporaryInteraction()
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(controller.debugSnapshot.escapeMonitorInstalled)
    }

    func testStreamingUpdateAfterPinRefreshesThePinnedPanel() throws {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(presentation("first"), actions: actions)
        controller.pinTemporary()
        let panel = try XCTUnwrap(controller.debugPinnedPanel)

        controller.updateTemporary(presentation("updated"))

        XCTAssertNil(controller.debugTemporaryPanel)
        XCTAssertTrue(controller.debugPinnedPanel === panel)
        XCTAssertEqual(panel.presentation?.resultText, "updated")
        XCTAssertEqual(controller.debugSnapshot.passiveOrderCount, 1)
    }

    func testDismissAllClosesBothPanelsAndEveryMonitor() {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(presentation("pin"), actions: actions)
        controller.pinTemporary()
        let pinned = controller.debugPinnedPanel
        controller.showTemporary(presentation("temporary"), actions: actions)
        let temporary = controller.debugTemporaryPanel
        controller.debugBeginTemporaryInteraction()

        controller.dismissAll()

        XCTAssertTrue(temporary?.didClose == true)
        XCTAssertTrue(pinned?.didClose == true)
        XCTAssertEqual(controller.debugSnapshot.temporaryCount, 0)
        XCTAssertEqual(controller.debugSnapshot.pinnedCount, 0)
        XCTAssertFalse(controller.debugSnapshot.clickAwayMonitorInstalled)
        XCTAssertFalse(controller.debugSnapshot.escapeMonitorInstalled)
    }

    func testLocalClickOnCoexistingPinnedPanelDismissesOnlyTemporary() throws {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(
            presentation(
                "pinned",
                displayRect: CGRect(x: 100, y: 500, width: 80, height: 20)
            ),
            actions: actions
        )
        controller.pinTemporary()
        let pinned = try XCTUnwrap(controller.debugPinnedPanel)
        controller.showTemporary(
            presentation(
                "temporary",
                displayRect: CGRect(x: 700, y: 500, width: 80, height: 20)
            ),
            actions: actions
        )
        let temporary = try XCTUnwrap(controller.debugTemporaryPanel)
        XCTAssertTrue(controller.debugSnapshot.localClickAwayMonitorInstalled)

        controller.debugHandleLocalMouseDown(
            at: CGPoint(x: pinned.frame.midX, y: pinned.frame.midY)
        )

        XCTAssertTrue(temporary.didClose)
        XCTAssertFalse(pinned.didClose)
        XCTAssertNil(controller.debugTemporaryPanel)
        XCTAssertTrue(controller.debugPinnedPanel === pinned)
    }

    func testUserDrivenDismissalsNotifyOwnerAndPinnedCloseTargetsPinnedOnly() throws {
        let controller = ResultPanelController(configuration: .testing)
        var temporaryCloses = 0
        var pinnedCloses = 0
        let temporaryActions = ResultPanelActions(
            copy: {}, retry: {}, changePreset: {},
            close: { temporaryCloses += 1 }
        )
        controller.showTemporary(presentation("escape"), actions: temporaryActions)
        controller.debugBeginTemporaryInteraction()
        controller.debugPressEscape()
        XCTAssertEqual(temporaryCloses, 1)
        XCTAssertEqual(controller.debugSnapshot.temporaryCount, 0)

        controller.showTemporary(
            presentation("pinned"),
            actions: ResultPanelActions(
                copy: {}, retry: {}, changePreset: {},
                close: { pinnedCloses += 1 }
            )
        )
        controller.pinTemporary()
        controller.showTemporary(presentation("new"), actions: temporaryActions)
        let temporary = try XCTUnwrap(controller.debugTemporaryPanel)
        controller.debugPinnedPanel?.resultActions?.close()
        XCTAssertEqual(pinnedCloses, 1)
        XCTAssertEqual(controller.debugSnapshot.pinnedCount, 0)
        XCTAssertTrue(controller.debugTemporaryPanel === temporary)

        controller.debugClickAway()
        XCTAssertEqual(temporaryCloses, 2)
        XCTAssertEqual(controller.debugSnapshot.temporaryCount, 0)
    }

    func testProgrammaticReplacementDoesNotCloseOwnerButPinnedReplacementDoes() {
        let controller = ResultPanelController(configuration: .testing)
        var firstCloses = 0
        let firstActions = ResultPanelActions(
            copy: {}, retry: {}, changePreset: {},
            close: { firstCloses += 1 }
        )

        controller.showTemporary(presentation("first"), actions: firstActions)
        controller.showTemporary(presentation("replacement"), actions: actions)
        XCTAssertEqual(firstCloses, 0)

        controller.pinTemporary()
        controller.showTemporary(presentation("second pinned"), actions: actions)
        controller.pinTemporary()
        XCTAssertEqual(firstCloses, 0)

        var pinnedCloses = 0
        controller.showTemporary(
            presentation("owned pinned"),
            actions: ResultPanelActions(
                copy: {}, retry: {}, changePreset: {},
                close: { pinnedCloses += 1 }
            )
        )
        controller.pinTemporary()
        XCTAssertEqual(pinnedCloses, 0)
        controller.showTemporary(presentation("new pinned"), actions: actions)
        controller.pinTemporary()
        XCTAssertEqual(pinnedCloses, 1)
    }

    func testTemporaryKeyResignationRemovesEscapeMonitorWithoutClosingPanels() throws {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(presentation("pin"), actions: actions)
        controller.pinTemporary()
        let pinned = try XCTUnwrap(controller.debugPinnedPanel)
        controller.showTemporary(presentation("temporary"), actions: actions)
        let temporary = try XCTUnwrap(controller.debugTemporaryPanel)
        controller.debugBeginTemporaryInteraction()
        XCTAssertTrue(controller.debugSnapshot.escapeMonitorInstalled)

        controller.debugTemporaryDidResignKey()

        XCTAssertFalse(controller.debugSnapshot.escapeMonitorInstalled)
        XCTAssertFalse(temporary.didClose)
        XCTAssertFalse(pinned.didClose)
        XCTAssertTrue(controller.debugTemporaryPanel === temporary)
        XCTAssertTrue(controller.debugPinnedPanel === pinned)
    }

    private var actions: ResultPanelActions {
        ResultPanelActions(copy: {}, retry: {}, changePreset: {}, close: {})
    }

    private func presentation(
        _ result: String,
        displayRect: CGRect = CGRect(x: 100, y: 500, width: 80, height: 20)
    ) -> TranslationPresentation {
        TranslationPresentation(
            sourceText: "source",
            resultText: result,
            presetID: PresetID(rawValue: "translate"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice,
            displayRect: displayRect,
            phase: .streaming
        )
    }
}
