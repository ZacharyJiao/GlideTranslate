import AppKit

final class PassiveResultPanel: NSPanel {
    var interactionEnabled = false
    var onDidBecomeKey: (@MainActor () -> Void)?
    var onDidResignKey: (@MainActor () -> Void)?
    var presentation: TranslationPresentation?
    var presentationModel: ResultPanelPresentationModel?
    var resultActions: ResultPanelActions?
    var ownerActions: ResultPanelActions?
    var anchorRect: CGRect?
    var anchorPointer: CGPoint = .zero
    var onUserResize: (@MainActor @Sendable (CGSize) -> Void)?
    var pendingResizeTask: Task<Void, Never>?
    private(set) var placement: PanelPlacement
    private(set) var didClose = false
    private var isApplyingAutomaticFrame = false

    override var canBecomeKey: Bool { interactionEnabled }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        placement = PanelPlacement(
            frame: contentRect,
            displayIndex: 0,
            displayID: "unassigned",
            reason: .pointer,
            side: .pointer
        )
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        acceptsMouseMovedEvents = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    func updatePlacement(_ placement: PanelPlacement) {
        self.placement = placement
    }

    func applyAutomaticFrame(
        _ frame: NSRect,
        animated: Bool,
        duration: TimeInterval = GlideMotionTokens.resizeDuration
    ) {
        isApplyingAutomaticFrame = true
        guard animated else {
            setFrame(frame, display: false)
            isApplyingAutomaticFrame = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.completionHandler = { [weak self] in
                self?.isApplyingAutomaticFrame = false
            }
            self.animator().setFrame(frame, display: false)
        }
    }

    func configurePinnedResizing(visibleFrame: CGRect) {
        styleMask.insert(.resizable)
        minSize = CGSize(
            width: min(
                PanelSizingPolicy.minimumSize.width,
                visibleFrame.width
            ),
            height: min(
                PanelSizingPolicy.minimumSize.height,
                visibleFrame.height
            )
        )
        maxSize = CGSize(
            width: max(minSize.width, visibleFrame.width),
            height: max(minSize.height, visibleFrame.height)
        )
    }

    func applyConstrainedManualFrame(_ frame: CGRect) {
        isApplyingAutomaticFrame = true
        setFrame(frame, display: true)
        isApplyingAutomaticFrame = false
    }

    var debugOutputTextView: NSTextView? {
        contentView?.layoutSubtreeIfNeeded()
        return contentView?.firstDescendant(of: NSTextView.self)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let oldSize = frame.size
        super.setFrame(frameRect, display: flag)
        notifyUserResizeIfNeeded(oldSize: oldSize, newSize: frameRect.size)
    }

    override func setFrame(
        _ frameRect: NSRect,
        display flag: Bool,
        animate animateFlag: Bool
    ) {
        let oldSize = frame.size
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        notifyUserResizeIfNeeded(oldSize: oldSize, newSize: frameRect.size)
    }

    private func notifyUserResizeIfNeeded(
        oldSize: NSSize,
        newSize: NSSize
    ) {
        guard !isApplyingAutomaticFrame,
              interactionEnabled,
              presentationModel?.isPinned == true,
              oldSize != newSize else { return }
        onUserResize?(newSize)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            beginInteraction(makeKey: true)
        }
        super.sendEvent(event)
    }

    override func close() {
        pendingResizeTask?.cancel()
        pendingResizeTask = nil
        didClose = true
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        onDidBecomeKey?()
    }

    override func resignKey() {
        super.resignKey()
        onDidResignKey?()
    }

    func beginInteraction(makeKey: Bool) {
        guard !interactionEnabled else { return }
        interactionEnabled = true
        if makeKey {
            self.makeKey()
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
