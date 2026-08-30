import CoreGraphics
import XCTest

@testable import GlideTranslate

final class PanelSizingPolicyTests: XCTestCase {
    func testInitialPreparingSizeUsesTheCompactMinimum() {
        XCTAssertEqual(
            PanelSizingPolicy.initialSize,
            CGSize(width: 380, height: 190)
        )
    }

    func testWidthTierBoundariesChooseCompactStandardThenReading() {
        let constraints = PanelSizingConstraints(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
            availableAnchorSpace: 900
        )

        let compact = PanelSizingPolicy.targetSize(
            for: measurement(
                collapsedSourceHeight: 30,
                resultHeights: [
                    .compact: 180,
                    .standard: 180,
                    .reading: 180,
                ]
            ),
            constraints: constraints
        )
        XCTAssertEqual(compact.tier, .compact)

        let standard = PanelSizingPolicy.targetSize(
            for: measurement(
                collapsedSourceHeight: 30,
                resultHeights: [
                    .compact: 250,
                    .standard: 300,
                    .reading: 300,
                ]
            ),
            constraints: constraints
        )
        XCTAssertEqual(standard.tier, .standard)

        let reading = PanelSizingPolicy.targetSize(
            for: measurement(
                collapsedSourceHeight: 30,
                resultHeights: [
                    .compact: 330,
                    .standard: 450,
                    .reading: 520,
                ]
            ),
            constraints: constraints
        )
        XCTAssertEqual(reading.tier, .reading)
    }

    func testHeightIsCappedBySmallestDisplayAndAnchorConstraint() {
        let decision = PanelSizingPolicy.targetSize(
            for: measurement(
                collapsedSourceHeight: 40,
                resultHeights: [
                    .compact: 600,
                    .standard: 600,
                    .reading: 600,
                ]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
                availableAnchorSpace: 350
            )
        )

        XCTAssertEqual(decision.maximumHeight, 350, accuracy: 0.001)
        XCTAssertEqual(decision.size.height, 350, accuracy: 0.001)
        XCTAssertTrue(decision.isHeightCapped)
    }

    func testWidthClampsToVisibleFrameSafetyMargin() {
        let decision = PanelSizingPolicy.targetSize(
            for: measurement(
                collapsedSourceHeight: 30,
                resultHeights: [
                    .compact: 360,
                    .standard: 480,
                    .reading: 620,
                ]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 800),
                availableAnchorSpace: 700
            )
        )

        XCTAssertEqual(decision.tier, .reading)
        XCTAssertEqual(decision.size.width, 376, accuracy: 0.001)
    }

    func testMissingMeasurementUsesTheFunctionalFallback() {
        let decision = PanelSizingPolicy.targetSize(
            for: PanelContentMeasurement(
                chromeHeight: 0,
                collapsedSourceHeight: 0,
                expandedSourceHeight: 0,
                resultHeights: [:]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                availableAnchorSpace: 700
            )
        )

        XCTAssertTrue(decision.usesFallback)
        XCTAssertEqual(decision.size, CGSize(width: 420, height: 240))
    }

    func testRenderedMeasurementAlwaysChoosesTierFromCollapsedSource() {
        let decision = PanelSizingPolicy.targetSize(
            for: PanelRenderedMeasurement(
                collapsedHeights: [
                    .compact: 180,
                    .standard: 340,
                    .reading: 480,
                ],
                expandedHeights: [
                    .compact: 900,
                    .standard: 900,
                    .reading: 900,
                ]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
                availableAnchorSpace: 900
            ),
            sourceExpanded: true
        )

        XCTAssertEqual(decision.tier, .compact)
        XCTAssertEqual(decision.desiredHeight, 900, accuracy: 0.001)
    }

    func testInvalidRenderedGeometryUsesFallback() {
        let decision = PanelSizingPolicy.targetSize(
            for: PanelRenderedMeasurement(
                collapsedHeights: [
                    .compact: .nan,
                    .standard: 300,
                    .reading: 300,
                ],
                expandedHeights: [
                    .compact: 300,
                    .standard: 300,
                    .reading: 300,
                ]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                availableAnchorSpace: 700
            )
        )

        XCTAssertTrue(decision.usesFallback)
        XCTAssertEqual(decision.size, CGSize(width: 420, height: 240))
    }

    func testActionOverflowUsesClampedAvailableWidthRatherThanLogicalTier() {
        let decision = PanelSizingPolicy.targetSize(
            for: PanelRenderedMeasurement(
                collapsedHeights: [
                    .compact: 500,
                    .standard: 500,
                    .reading: 500,
                ],
                expandedHeights: [
                    .compact: 500,
                    .standard: 500,
                    .reading: 500,
                ]
            ),
            constraints: PanelSizingConstraints(
                visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 800),
                availableAnchorSpace: 700
            )
        )

        XCTAssertEqual(decision.tier, .reading)
        XCTAssertEqual(decision.size.width, 376, accuracy: 0.001)
        XCTAssertEqual(decision.actionLayout, .compactOverflow)
        XCTAssertLessThanOrEqual(
            decision.actionBarAvailableWidth,
            PanelSizingPolicy.fullActionBarMinimumWidth
        )
    }

    private func measurement(
        chromeHeight: CGFloat = 100,
        collapsedSourceHeight: CGFloat,
        resultHeights: [PanelWidthTier: CGFloat]
    ) -> PanelContentMeasurement {
        PanelContentMeasurement(
            chromeHeight: chromeHeight,
            collapsedSourceHeight: collapsedSourceHeight,
            expandedSourceHeight: 120,
            resultHeights: resultHeights,
            verticalSpacing: 10
        )
    }
}
