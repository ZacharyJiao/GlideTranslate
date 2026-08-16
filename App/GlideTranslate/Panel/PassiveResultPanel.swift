import AppKit

final class PassiveResultPanel: NSPanel {
    var interactionEnabled = false
    var onDidBecomeKey: (@MainActor () -> Void)?
    var onDidResignKey: (@MainActor () -> Void)?
    var presentation: TranslationPresentation?
    var resultActions: ResultPanelActions?
    var ownerActions: ResultPanelActions?
    private(set) var didClose = false

    override var canBecomeKey: Bool { interactionEnabled }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            beginInteraction(makeKey: true)
        }
        super.sendEvent(event)
    }

    override func close() {
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
