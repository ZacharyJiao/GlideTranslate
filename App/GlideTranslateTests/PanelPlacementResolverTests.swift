import CoreGraphics
import XCTest

@testable import GlideTranslate

final class PanelPlacementResolverTests: XCTestCase {
    private struct PlacementRow {
        let name: String
        let selection: CGRect?
        let pointer: CGPoint
        let displays: [CGRect]
        let panelSize: CGSize
        let expectedFrame: CGRect?
        let expectedDisplay: Int
        let expectedReason: PanelPlacementReason?
        let nonoverlapPossible: Bool
    }

    func testCompleteGeometryTable() throws {
        let primary = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let dualDisplays = [
            primary,
            CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
        ]
        let spanningDisplays = [
            primary,
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        ]
        let rows: [PlacementRow] = [
            .init(
                name: "below",
                selection: CGRect(x: 100, y: 500, width: 80, height: 20),
                pointer: CGPoint(x: 120, y: 510),
                displays: [primary],
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 100, y: 248, width: 420, height: 240),
                expectedDisplay: 0,
                expectedReason: .below,
                nonoverlapPossible: true
            ),
            .init(
                name: "above",
                selection: CGRect(x: 100, y: 20, width: 80, height: 20),
                pointer: CGPoint(x: 120, y: 30),
                displays: [primary],
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 100, y: 52, width: 420, height: 240),
                expectedDisplay: 0,
                expectedReason: .above,
                nonoverlapPossible: true
            ),
            .init(
                name: "right edge clamped",
                selection: CGRect(x: 970, y: 500, width: 20, height: 20),
                pointer: CGPoint(x: 980, y: 510),
                displays: [primary],
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 580, y: 248, width: 420, height: 240),
                expectedDisplay: 0,
                expectedReason: .clamped,
                nonoverlapPossible: true
            ),
            .init(
                name: "top edge selection still prefers below",
                selection: CGRect(x: 100, y: 770, width: 80, height: 20),
                pointer: CGPoint(x: 120, y: 780),
                displays: [primary],
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 100, y: 518, width: 420, height: 240),
                expectedDisplay: 0,
                expectedReason: .below,
                nonoverlapPossible: true
            ),
            .init(
                name: "negative-origin second display",
                selection: CGRect(x: -700, y: 400, width: 80, height: 20),
                pointer: CGPoint(x: -660, y: 410),
                displays: dualDisplays,
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: -700, y: 148, width: 420, height: 240),
                expectedDisplay: 1,
                expectedReason: .below,
                nonoverlapPossible: true
            ),
            .init(
                name: "pointer fallback",
                selection: nil,
                pointer: CGPoint(x: 900, y: 700),
                displays: [primary],
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 580, y: 448, width: 420, height: 240),
                expectedDisplay: 0,
                expectedReason: .clamped,
                nonoverlapPossible: false
            ),
            .init(
                name: "selection spanning displays uses midpoint display",
                selection: CGRect(x: 900, y: 400, width: 300, height: 20),
                pointer: CGPoint(x: 910, y: 410),
                displays: spanningDisplays,
                panelSize: PanelPlacementResolver.defaultPanelSize,
                expectedFrame: CGRect(x: 1_000, y: 148, width: 420, height: 240),
                expectedDisplay: 1,
                expectedReason: .clamped,
                nonoverlapPossible: true
            ),
            .init(
                name: "panel larger than visible frame",
                selection: nil,
                pointer: CGPoint(x: 500, y: 400),
                displays: [primary],
                panelSize: CGSize(width: 1_200, height: 900),
                expectedFrame: primary,
                expectedDisplay: 0,
                expectedReason: .clamped,
                nonoverlapPossible: false
            )
        ]

        for row in rows {
            let placement = try XCTUnwrap(PanelPlacementResolver.resolve(
                selection: row.selection,
                pointer: row.pointer,
                visibleFrames: row.displays,
                panelSize: row.panelSize
            ), row.name)
            XCTAssertEqual(placement.displayIndex, row.expectedDisplay, row.name)
            XCTAssertEqual(placement.reason, row.expectedReason, row.name)
            if let expectedFrame = row.expectedFrame {
                XCTAssertEqual(placement.frame, expectedFrame, row.name)
            }
            XCTAssertTrue(
                row.displays[row.expectedDisplay].contains(placement.frame),
                row.name
            )
            if row.nonoverlapPossible, let selection = row.selection {
                XCTAssertFalse(placement.frame.intersects(selection), row.name)
            }
        }
    }

    func testC3ConvertedRectanglesChooseTheSameDisplayWithoutAnotherConversion() throws {
        let displays = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
            CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 900, width: 1_024, height: 768),
            CGRect(x: 200, y: -720, width: 1_280, height: 720)
        ]
        let convertedRows: [(String, CGRect, Int)] = [
            ("main", CGRect(x: 100, y: 680, width: 50, height: 20), 0),
            ("left", CGRect(x: -1_200, y: 670, width: 40, height: 30), 1),
            ("right", CGRect(x: 1_500, y: 760, width: 60, height: 40), 2),
            ("above", CGRect(x: 100, y: 1_580, width: 30, height: 20), 3),
            ("below", CGRect(x: 300, y: -120, width: 80, height: 20), 4)
        ]

        for (name, selection, expectedDisplay) in convertedRows {
            let placement = try XCTUnwrap(PanelPlacementResolver.resolve(
                selection: selection,
                pointer: CGPoint(x: selection.midX, y: selection.midY),
                visibleFrames: displays
            ), name)
            XCTAssertEqual(placement.displayIndex, expectedDisplay, name)
            XCTAssertTrue(displays[expectedDisplay].contains(placement.frame), name)
            XCTAssertFalse(placement.frame.intersects(selection), name)
        }
    }

    func testNonfiniteInputsFallBackToPointerThenDisplayCenter() throws {
        let displays = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
        ]
        let invalidSelection = CGRect(
            x: CGFloat.infinity,
            y: 0,
            width: 20,
            height: 20
        )
        let pointerFallback = try XCTUnwrap(PanelPlacementResolver.resolve(
            selection: invalidSelection,
            pointer: CGPoint(x: -500, y: 400),
            visibleFrames: displays
        ))
        XCTAssertEqual(pointerFallback.displayIndex, 1)
        XCTAssertTrue(displays[1].contains(pointerFallback.frame))

        let centerFallback = try XCTUnwrap(PanelPlacementResolver.resolve(
            selection: invalidSelection,
            pointer: CGPoint(x: CGFloat.infinity, y: CGFloat.infinity),
            visibleFrames: displays
        ))
        XCTAssertEqual(centerFallback.displayIndex, 0)
        XCTAssertTrue(displays[0].contains(centerFallback.frame))
    }

    func testNonfiniteGapFallsBackToTheFixedTwelvePointGap() throws {
        let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let placement = try XCTUnwrap(PanelPlacementResolver.resolve(
            selection: nil,
            pointer: CGPoint(x: 100, y: 500),
            visibleFrames: [display],
            gap: CGFloat.nan
        ))

        XCTAssertEqual(
            placement.frame,
            CGRect(x: 112, y: 248, width: 420, height: 240)
        )
        XCTAssertEqual(placement.reason, .pointer)
        XCTAssertTrue(display.contains(placement.frame))
    }

    func testPointerPlacementAndEqualDistanceDisplaySelectionAreDeterministic() throws {
        let first = CGRect(x: 0, y: 0, width: 400, height: 800)
        let second = CGRect(x: 600, y: 0, width: 400, height: 800)

        let interior = try XCTUnwrap(PanelPlacementResolver.resolve(
            selection: nil,
            pointer: CGPoint(x: 100, y: 500),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
        ))
        XCTAssertEqual(interior.reason, .pointer)
        XCTAssertEqual(
            interior.frame,
            CGRect(x: 112, y: 248, width: 420, height: 240)
        )

        let tied = try XCTUnwrap(PanelPlacementResolver.resolve(
            selection: nil,
            pointer: CGPoint(x: 500, y: 400),
            visibleFrames: [first, second],
            panelSize: CGSize(width: 200, height: 200)
        ))
        XCTAssertEqual(tied.displayIndex, 0)
        XCTAssertTrue(first.contains(tied.frame))
    }

    func testNoUsableVisibleFrameReturnsNil() {
        XCTAssertNil(PanelPlacementResolver.resolve(
            selection: nil,
            pointer: .zero,
            visibleFrames: []
        ))
        XCTAssertNil(PanelPlacementResolver.resolve(
            selection: nil,
            pointer: .zero,
            visibleFrames: [CGRect(
                x: 0,
                y: 0,
                width: CGFloat.infinity,
                height: 800
            )]
        ))
    }
}
