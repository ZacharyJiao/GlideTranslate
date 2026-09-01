import CoreGraphics
import Observation

@MainActor
@Observable
final class ResultPanelPresentationModel {
    var presentation: TranslationPresentation
    var isPinned: Bool
    var isSourceExpanded = false
    var followsLatest = true
    var showsBackToLatest = false
    private(set) var latestScrollRequest = 0
    var widthTier: PanelWidthTier = .compact
    var actionLayout: PanelActionLayout = .compactOverflow
    var usesFallbackSizing = false
    private(set) var automaticSize: CGSize
    private(set) var automaticSizingEnabled = true
    private(set) var pendingSizingDecision: PanelSizingDecision?

    private var lastAutomaticResizeTime: Double = -.infinity
    private let requestSnapshot: TranslationPresentation
    private var viewportHeight: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var scrollOffsetFromBottom: CGFloat = 0

    init(
        presentation: TranslationPresentation,
        isPinned: Bool,
        initialSize: CGSize = PanelSizingPolicy.initialSize
    ) {
        self.presentation = presentation
        requestSnapshot = presentation
        self.isPinned = isPinned
        automaticSize = initialSize.isFiniteAndPositive
            ? initialSize
            : PanelSizingPolicy.initialSize
        actionLayout = PanelSizingPolicy.actionLayout(for: automaticSize.width)
    }

    func updatePresentation(_ presentation: TranslationPresentation) {
        self.presentation = TranslationPresentation(
            sourceText: requestSnapshot.sourceText,
            resultText: presentation.resultText,
            presetID: requestSnapshot.presetID,
            presetDisplayName: requestSnapshot.presetDisplayName,
            sourceLanguage: requestSnapshot.sourceLanguage,
            targetLanguage: requestSnapshot.targetLanguage,
            providerClass: requestSnapshot.providerClass,
            displayRect: requestSnapshot.displayRect,
            phase: presentation.phase
        )
    }

    func toggleSourceExpansion() {
        isSourceExpanded.toggle()
    }

    func updateScrollState(
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        offsetFromBottom: CGFloat,
        userInitiated: Bool = false
    ) {
        let previousOffsetFromBottom = scrollOffsetFromBottom
        self.viewportHeight = max(0, viewportHeight)
        self.contentHeight = max(0, contentHeight)
        scrollOffsetFromBottom = max(0, offsetFromBottom)
        if userInitiated {
            if scrollOffsetFromBottom > previousOffsetFromBottom + 0.5 {
                followsLatest = false
            } else if scrollOffsetFromBottom <= 0.5 {
                followsLatest = true
            }
        } else if followsLatest {
            followsLatest = scrollOffsetFromBottom <= 24
        }
        showsBackToLatest = !followsLatest && self.contentHeight > self.viewportHeight
    }

    func userDidBeginScrolling() {
        followsLatest = false
        showsBackToLatest = contentHeight > viewportHeight
    }

    func scrollbarDidBeginDragging() {
        userDidBeginScrolling()
    }

    func userDidReachLatest() {
        backToLatest()
    }

    func backToLatest() {
        scrollOffsetFromBottom = 0
        followsLatest = true
        showsBackToLatest = false
        latestScrollRequest &+= 1
    }

    @discardableResult
    func applyAutomaticSize(
        _ size: CGSize,
        at time: Double
    ) -> Bool {
        applySizingDecision(
            PanelSizingDecision(
                tier: widthTier,
                size: size,
                desiredHeight: size.height,
                maximumHeight: size.height,
                isHeightCapped: false,
                usesFallback: false,
                actionLayout: PanelSizingPolicy.actionLayout(for: size.width)
            ),
            at: time
        )
    }

    @discardableResult
    func applyManualResize(_ size: CGSize) -> Bool {
        guard isPinned, size.isFiniteAndPositive else { return false }
        automaticSize = size
        automaticSizingEnabled = false
        pendingSizingDecision = nil
        actionLayout = PanelSizingPolicy.actionLayout(for: automaticSize.width)
        return true
    }

    func applySizingDecision(
        _ decision: PanelSizingDecision,
        at time: Double
    ) -> Bool {
        guard automaticSizingEnabled,
              decision.size.isFiniteAndPositive else { return false }
        if time - lastAutomaticResizeTime < 0.1 {
            pendingSizingDecision = decision
            return false
        }
        pendingSizingDecision = nil
        return commit(decision, at: time)
    }

    @discardableResult
    func flushPendingSizing(at time: Double) -> Bool {
        guard automaticSizingEnabled,
              let pendingSizingDecision,
              time - lastAutomaticResizeTime >= 0.1 else { return false }
        self.pendingSizingDecision = nil
        return commit(pendingSizingDecision, at: time)
    }

    func reclampAutomaticSize(_ size: CGSize) {
        guard size.isFiniteAndPositive else { return }
        automaticSize = size
        actionLayout = PanelSizingPolicy.actionLayout(for: size.width)
    }

    func resetAutomaticSizingForNewRequest() {
        automaticSizingEnabled = true
        automaticSize = PanelSizingPolicy.initialSize
        widthTier = .compact
        usesFallbackSizing = false
        actionLayout = .compactOverflow
        lastAutomaticResizeTime = -.infinity
        pendingSizingDecision = nil
        isSourceExpanded = false
        followsLatest = true
        showsBackToLatest = false
    }

    private func commit(
        _ decision: PanelSizingDecision,
        at time: Double
    ) -> Bool {
        let previousSize = automaticSize
        let growOnly = CGSize(
            width: max(previousSize.width, decision.size.width),
            height: max(previousSize.height, decision.size.height)
        )
        guard growOnly != previousSize else { return false }
        automaticSize = growOnly
        if decision.size.width >= previousSize.width {
            widthTier = decision.tier
        }
        actionLayout = PanelSizingPolicy.actionLayout(for: growOnly.width)
        usesFallbackSizing = decision.usesFallback
        lastAutomaticResizeTime = time
        return true
    }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
