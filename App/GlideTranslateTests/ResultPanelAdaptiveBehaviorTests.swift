import AppKit
import CoreGraphics
import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class ResultPanelAdaptiveBehaviorTests: XCTestCase {
    func testProductionMeasurementUsesRenderedGeometryAtEveryTier() throws {
        let short = try XCTUnwrap(
            PanelContentMeasurer.measure(
                presentation: presentation(
                    source: "synthetic",
                    result: "short"
                ),
                appearance: nil
            )
        )
        let paragraph = try XCTUnwrap(
            PanelContentMeasurer.measure(
                presentation: presentation(
                    source: "合成源文本",
                    result: String(repeating: "合成长段落内容。", count: 80)
                ),
                appearance: nil
            )
        )

        for tier in PanelWidthTier.allCases {
            XCTAssertNotNil(short.collapsedHeights[tier])
            XCTAssertNotNil(paragraph.collapsedHeights[tier])
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(paragraph.collapsedHeights[.compact]),
            try XCTUnwrap(short.collapsedHeights[.compact])
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(paragraph.collapsedHeights[.compact]),
            try XCTUnwrap(paragraph.collapsedHeights[.reading])
        )
    }

    func testStreamingUpdatesReuseOneHostingViewAndPreserveRequestSnapshot() throws {
        let controller = ResultPanelController(configuration: .testing)
        let initialResult = String(repeating: "synthetic line ", count: 120)
        let original = presentation(
            source: "synthetic source",
            result: initialResult,
            displayRect: CGRect(x: 100, y: 500, width: 80, height: 20)
        )
        controller.showTemporary(original, actions: actions)
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        let hostingView = try XCTUnwrap(panel.contentView)
        let outputView = try XCTUnwrap(panel.debugOutputTextView)
        XCTAssertTrue(outputView.isVerticallyResizable)
        XCTAssertFalse(outputView.isHorizontallyResizable)
        XCTAssertTrue(outputView.textContainer?.widthTracksTextView == true)
        outputView.setSelectedRange(NSRange(location: 0, length: 9))
        let scrollView = try XCTUnwrap(outputView.enclosingScrollView)
        scrollView.contentView.setBoundsOrigin(.zero)
        let readingOrigin = scrollView.contentView.bounds.origin

        controller.updateTemporary(
            presentation(
                source: "synthetic source",
                result: initialResult + " appended",
                displayRect: original.displayRect
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.contentView === hostingView)
        XCTAssertTrue(panel.debugOutputTextView === outputView)
        XCTAssertTrue(outputView.string.hasSuffix(" appended"))
        XCTAssertEqual(panel.presentation?.displayRect, original.displayRect)
        XCTAssertEqual(panel.presentation?.sourceText, original.sourceText)
        XCTAssertEqual(panel.presentation?.resultText, initialResult + " appended")
        XCTAssertEqual(outputView.selectedRange(), NSRange(location: 0, length: 9))
        XCTAssertEqual(scrollView.contentView.bounds.origin, readingOrigin)
    }

    func testFirstUserScrollTickStopsStreamingFromForcingTheOutputBackToBottom() throws {
        let controller = ResultPanelController(configuration: .testing)
        let initialResult = String(repeating: "synthetic streaming line\n", count: 160)
        controller.showTemporary(
            presentation(source: "synthetic source", result: initialResult),
            actions: actions
        )

        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        let model = try XCTUnwrap(panel.presentationModel)
        let outputView = try XCTUnwrap(panel.debugOutputTextView)
        let scrollView = try XCTUnwrap(outputView.enclosingScrollView)
        controller.updateTemporary(
            presentation(
                source: "synthetic source",
                result: initialResult + "sizing token"
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        panel.contentView?.layoutSubtreeIfNeeded()
        outputView.scrollRangeToVisible(
            NSRange(location: outputView.string.utf16.count, length: 0)
        )
        let bottomOrigin = scrollView.contentView.bounds.origin
        XCTAssertGreaterThan(bottomOrigin.y, 4)

        let userOrigin = CGPoint(x: bottomOrigin.x, y: bottomOrigin.y - 4)
        scrollView.contentView.setBoundsOrigin(userOrigin)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertFalse(model.followsLatest)

        controller.updateTemporary(
            presentation(
                source: "synthetic source",
                result: initialResult + "sizing token and one more token"
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(scrollView.contentView.bounds.origin, userOrigin)
    }

    func testControllerUsesRenderedGeometryAndFallsBackWhenMeasurementFails() throws {
        let renderedMeasurement = PanelRenderedMeasurement(
            collapsedHeights: [
                .compact: 380,
                .standard: 340,
                .reading: 340,
            ],
            expandedHeights: [
                .compact: 380,
                .standard: 340,
                .reading: 340,
            ]
        )
        let controller = ResultPanelController(
            configuration: .testing(measurement: { _, _ in renderedMeasurement })
        )
        controller.showTemporary(
            presentation(source: "synthetic", result: "output"),
            actions: actions
        )
        controller.updateTemporary(
            presentation(source: "synthetic", result: "streamed output")
        )

        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        XCTAssertEqual(panel.presentationModel?.widthTier, .standard)
        XCTAssertFalse(panel.presentationModel?.usesFallbackSizing == true)

        let fallbackController = ResultPanelController(
            configuration: .testing(measurement: { _, _ in nil })
        )
        fallbackController.showTemporary(
            presentation(source: "synthetic", result: "output"),
            actions: actions
        )
        fallbackController.updateTemporary(
            presentation(source: "synthetic", result: String(repeating: "stream ", count: 200))
        )
        let fallbackPanel = try XCTUnwrap(fallbackController.debugTemporaryPanel)
        XCTAssertTrue(fallbackPanel.presentationModel?.usesFallbackSizing == true)
        XCTAssertEqual(
            fallbackPanel.presentationModel?.automaticSize,
            PanelSizingPolicy.fallbackSize
        )
    }

    func testStreamingSizingIsGrowOnlyAndCoalescedAtOneUpdatePerHundredMilliseconds() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: ""),
            isPinned: false
        )

        XCTAssertTrue(model.applyAutomaticSize(
            CGSize(width: 380, height: 220), at: 0
        ))
        XCTAssertFalse(model.applyAutomaticSize(
            CGSize(width: 380, height: 280), at: 0.05
        ))
        XCTAssertTrue(model.applyAutomaticSize(
            CGSize(width: 380, height: 280), at: 0.11
        ))
        XCTAssertFalse(model.applyAutomaticSize(
            CGSize(width: 380, height: 200), at: 0.25
        ))
        XCTAssertEqual(model.automaticSize.height, 280, accuracy: 0.001)
    }

    func testSizingBurstAppliesOnlyTheLatestPendingDecisionAtTheBoundary() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: ""),
            isPinned: false
        )
        let first = decision(width: 460, height: 260, tier: .standard)
        let second = decision(width: 560, height: 420, tier: .reading)

        XCTAssertTrue(model.applySizingDecision(first, at: 0))
        XCTAssertFalse(model.applySizingDecision(second, at: 0.04))
        XCTAssertEqual(model.pendingSizingDecision?.size, second.size)
        XCTAssertFalse(model.flushPendingSizing(at: 0.09))
        XCTAssertTrue(model.flushPendingSizing(at: 0.10))
        XCTAssertEqual(model.automaticSize, second.size)
        XCTAssertEqual(model.widthTier, .reading)
    }

    func testAcceptedMixedDimensionSizingNeverShrinksEitherDimension() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: ""),
            isPinned: false
        )
        XCTAssertTrue(
            model.applySizingDecision(
                decision(width: 560, height: 420, tier: .reading),
                at: 0
            )
        )
        XCTAssertTrue(
            model.applySizingDecision(
                decision(width: 460, height: 540, tier: .standard),
                at: 0.11
            )
        )
        XCTAssertEqual(model.automaticSize.width, 560, accuracy: 0.001)
        XCTAssertEqual(model.automaticSize.height, 540, accuracy: 0.001)
        XCTAssertEqual(model.widthTier, .reading)
    }

    func testScrollAwayStopsFollowingAndBackToLatestRestoresIt() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: "output"),
            isPinned: false
        )

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 20
        )
        XCTAssertTrue(model.followsLatest)
        XCTAssertFalse(model.showsBackToLatest)

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 24
        )
        XCTAssertTrue(model.followsLatest)

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 24.1
        )
        XCTAssertFalse(model.followsLatest)
        XCTAssertTrue(model.showsBackToLatest)

        model.backToLatest()
        XCTAssertTrue(model.followsLatest)
        XCTAssertFalse(model.showsBackToLatest)
    }

    func testUserScrollSuspensionSurvivesProgrammaticBottomMeasurement() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: "output"),
            isPinned: false
        )

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 120,
            userInitiated: true
        )
        XCTAssertFalse(model.followsLatest)

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 0,
            userInitiated: false
        )
        XCTAssertFalse(model.followsLatest)

        model.backToLatest()
        XCTAssertTrue(model.followsLatest)
    }

    func testUserScrollIntentSuspendsBeforeImmediateStreamingUpdate() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(
                source: "synthetic",
                result: String(repeating: "output\n", count: 120)
            ),
            isPinned: false
        )

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 0
        )
        model.userDidBeginScrolling()
        model.updatePresentation(
            presentation(
                source: "synthetic",
                result: String(repeating: "output\n", count: 121)
            )
        )

        XCTAssertFalse(model.followsLatest)
        XCTAssertTrue(model.showsBackToLatest)
        model.userDidReachLatest()
        XCTAssertTrue(model.followsLatest)
    }

    func testScrollbarIntentAlsoSuspendsBeforeStreamingUpdate() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic", result: "output"),
            isPinned: false
        )

        model.updateScrollState(
            viewportHeight: 200,
            contentHeight: 700,
            offsetFromBottom: 0
        )
        model.scrollbarDidBeginDragging()
        model.updatePresentation(
            presentation(source: "synthetic", result: "output and one more chunk")
        )

        XCTAssertFalse(model.followsLatest)
        model.userDidReachLatest()
        XCTAssertTrue(model.followsLatest)
    }

    func testWheelEventSuspendsBeforeTheNextRenderedChunk() throws {
        let controller = ResultPanelController(configuration: .testing)
        let initial = String(repeating: "streaming line\n", count: 180)
        controller.showTemporary(
            presentation(source: "synthetic", result: initial),
            actions: actions
        )
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        let model = try XCTUnwrap(panel.presentationModel)
        let output = try XCTUnwrap(panel.debugOutputTextView)
        let scrollView = try XCTUnwrap(output.enclosingScrollView)
        controller.updateTemporary(
            presentation(source: "synthetic", result: initial + " initial chunk")
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        output.scrollRangeToVisible(NSRange(location: output.string.utf16.count, length: 0))

        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 60,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)))
        scrollView.scrollWheel(with: event)
        let currentOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.setBoundsOrigin(CGPoint(
            x: currentOrigin.x,
            y: max(0, currentOrigin.y - 80)
        ))
        let userOrigin = scrollView.contentView.bounds.origin
        controller.updateTemporary(
            presentation(source: "synthetic", result: initial + " initial chunk and next")
        )

        XCTAssertFalse(model.followsLatest)
        XCTAssertTrue(model.showsBackToLatest)
        XCTAssertEqual(scrollView.contentView.bounds.origin, userOrigin)
    }

    func testScrollbarKnobDragSuspendsBeforeTheNextRenderedChunk() throws {
        let controller = ResultPanelController(configuration: .testing)
        let initial = String(repeating: "streaming line\n", count: 180)
        controller.showTemporary(
            presentation(source: "synthetic", result: initial),
            actions: actions
        )
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        let model = try XCTUnwrap(panel.presentationModel)
        let output = try XCTUnwrap(panel.debugOutputTextView)
        let scrollView = try XCTUnwrap(output.enclosingScrollView)
        controller.updateTemporary(
            presentation(source: "synthetic", result: initial + " initial chunk")
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        output.scrollRangeToVisible(NSRange(location: output.string.utf16.count, length: 0))
        let scroller = try XCTUnwrap(
            scrollView.verticalScroller as? ResultPanelIntentAwareScroller
        )
        scroller.beginUserScroll()
        controller.updateTemporary(
            presentation(source: "synthetic", result: initial + " initial chunk and next")
        )

        XCTAssertFalse(model.followsLatest)
        XCTAssertTrue(model.showsBackToLatest)
    }

    func testSourceDisclosureAndPinnedManualResizeOwnState() {
        let model = ResultPanelPresentationModel(
            presentation: presentation(source: "synthetic source", result: "output"),
            isPinned: true
        )

        XCTAssertFalse(model.isSourceExpanded)
        model.toggleSourceExpansion()
        XCTAssertTrue(model.isSourceExpanded)

        XCTAssertTrue(model.applyManualResize(CGSize(width: 500, height: 420)))
        XCTAssertFalse(model.automaticSizingEnabled)
        let manualSize = model.automaticSize

        XCTAssertFalse(model.applyAutomaticSize(
            CGSize(width: 560, height: 540), at: 1
        ))
        XCTAssertEqual(model.automaticSize, manualSize)
    }

    func testPinnedPanelBecomesNativelyResizableAndFirstRealResizeDisablesAutomation() throws {
        let controller = ResultPanelController(configuration: .testing)
        controller.showTemporary(presentation(source: "synthetic", result: "output"), actions: actions)
        controller.pinTemporary()

        let panel = try XCTUnwrap(controller.debugPinnedPanel)
        let model = try XCTUnwrap(panel.presentationModel)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(panel.minSize.width, PanelSizingPolicy.minimumSize.width)
        XCTAssertGreaterThanOrEqual(panel.minSize.height, PanelSizingPolicy.minimumSize.height)
        XCTAssertLessThanOrEqual(panel.maxSize.width, 1_000)
        XCTAssertLessThanOrEqual(panel.maxSize.height, 800)

        let frame = panel.frame
        panel.setFrame(
            CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width + 40,
                height: frame.height + 30
            ),
            display: false
        )

        XCTAssertFalse(model.automaticSizingEnabled)
        XCTAssertLessThanOrEqual(panel.frame.maxX, 1_000)
        XCTAssertLessThanOrEqual(panel.frame.maxY, 800)
    }

    func testScreenReorderAndRemovalUsesStableDisplayIdentityAndReclamps() throws {
        var displays = [
            PanelDisplay(id: "left", visibleFrame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800)),
            PanelDisplay(id: "right", visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)),
        ]
        let configuration = ResultPanelController.Configuration.testing(
            displays: { displays }
        )
        let controller = ResultPanelController(configuration: configuration)
        controller.showTemporary(
            presentation(
                source: "synthetic",
                result: "output",
                displayRect: CGRect(x: 100, y: 500, width: 80, height: 20)
            ),
            actions: actions
        )
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        XCTAssertEqual(panel.placement.displayID, "right")

        displays = [displays[1], displays[0]]
        controller.debugScreenParametersChanged()
        XCTAssertEqual(panel.placement.displayID, "right")

        displays = [displays[1]]
        controller.debugScreenParametersChanged()
        XCTAssertEqual(panel.placement.displayID, "left")
        XCTAssertTrue(displays[0].visibleFrame.contains(panel.frame))
    }

    func testPointerCornerRemainsIndependentFromMissingSelectionAndGrowth() throws {
        let display = CGRect(x: -1_000, y: -200, width: 1_000, height: 800)
        let placement = try XCTUnwrap(
            PanelPlacementResolver.resolve(
                selection: nil,
                pointer: CGPoint(x: -600, y: 200),
                visibleFrames: [display],
                panelSize: CGSize(width: 380, height: 190),
                preferredPointerCorner: .topLeft
            )
        )
        XCTAssertEqual(placement.pointerCorner, .topLeft)

        let controller = ResultPanelController(
            configuration: .testing(
                pointer: { CGPoint(x: -600, y: 200) },
                visibleFrames: { [display] },
                measurement: { _, _ in
                    PanelRenderedMeasurement(
                        collapsedHeights: [.compact: 200, .standard: 300, .reading: 300],
                        expandedHeights: [.compact: 200, .standard: 300, .reading: 300]
                    )
                }
            )
        )
        controller.showTemporary(
            presentation(source: "synthetic", result: "short", displayRect: nil),
            actions: actions
        )
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        XCTAssertEqual(panel.placement.pointerCorner, .topLeft)
        let anchor = panel.anchorPointer
        controller.updateTemporary(
            presentation(source: "synthetic", result: String(repeating: "long ", count: 200), displayRect: nil)
        )
        XCTAssertEqual(panel.placement.pointerCorner, .topLeft)
        XCTAssertEqual(panel.frame.minX, anchor.x + PanelPlacementResolver.defaultGap, accuracy: 0.001)
    }

    func testAccessibilityBranchesAndEntryMotionAreTypedAndReduceMotionIsImmediate() {
        XCTAssertEqual(
            PanelSurfaceStyle.resolve(reduceTransparency: true, increaseContrast: false),
            .reducedTransparency
        )
        XCTAssertEqual(
            PanelSurfaceStyle.resolve(reduceTransparency: false, increaseContrast: true),
            .increasedContrast
        )
        XCTAssertEqual(
            PanelMotionPolicy.entryOffset(side: .below, pointerCorner: nil),
            CGSize(width: 0, height: -8)
        )
        XCTAssertEqual(
            PanelMotionPolicy.entryOffset(side: .pointer, pointerCorner: .topLeft),
            CGSize(width: 8, height: -8)
        )
        XCTAssertTrue(PanelMotionPolicy.shouldApplyImmediately(reduceMotion: true))
        XCTAssertFalse(PanelMotionPolicy.shouldApplyImmediately(reduceMotion: false))
    }

    func testAnchorSideRemainsStableWhenStreamingContentGrows() throws {
        let controller = ResultPanelController(configuration: .testing)
        let displayRect = CGRect(x: 100, y: 500, width: 80, height: 20)
        controller.showTemporary(
            presentation(source: "synthetic", result: "short", displayRect: displayRect),
            actions: actions
        )
        let panel = try XCTUnwrap(controller.debugTemporaryPanel)
        let initialSide = panel.placement.side

        controller.updateTemporary(
            presentation(
                source: "synthetic",
                result: String(repeating: "streamed ", count: 100),
                displayRect: displayRect
            )
        )

        XCTAssertEqual(panel.placement.side, initialSide)
    }

    private var actions: ResultPanelActions {
        ResultPanelActions(copy: {}, retry: {}, changePreset: {}, close: {})
    }

    private func presentation(
        source: String,
        result: String,
        displayRect: CGRect? = CGRect(x: 100, y: 500, width: 80, height: 20)
    ) -> TranslationPresentation {
        TranslationPresentation(
            sourceText: source,
            resultText: result,
            presetID: PresetID(rawValue: "translate"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice,
            displayRect: displayRect,
            phase: .streaming
        )
    }

    private func decision(
        width: CGFloat,
        height: CGFloat,
        tier: PanelWidthTier
    ) -> PanelSizingDecision {
        PanelSizingDecision(
            tier: tier,
            size: CGSize(width: width, height: height),
            desiredHeight: height,
            maximumHeight: height,
            isHeightCapped: false,
            usesFallback: false,
            actionLayout: PanelSizingPolicy.actionLayout(for: width)
        )
    }
}
