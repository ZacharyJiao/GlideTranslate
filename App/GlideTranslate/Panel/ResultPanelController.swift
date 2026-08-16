import AppKit
import QuartzCore
import SharedSupport
import SwiftUI

enum TranslationPresentationPhase: String, Equatable, Sendable {
    case preparing
    case connecting
    case waitingForFirstToken
    case streaming
    case completed
    case failed
}

struct TranslationPresentation: Equatable, Sendable {
    let sourceText: String
    let resultText: String
    let presetID: PresetID
    let presetDisplayName: String?
    let sourceLanguage: LanguageChoice
    let targetLanguage: LanguageChoice
    let providerClass: DestinationPrivacyClass
    let displayRect: CGRect?
    let phase: TranslationPresentationPhase

    init(
        sourceText: String,
        resultText: String,
        presetID: PresetID,
        presetDisplayName: String? = nil,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        providerClass: DestinationPrivacyClass,
        displayRect: CGRect?,
        phase: TranslationPresentationPhase
    ) {
        self.sourceText = sourceText
        self.resultText = resultText
        self.presetID = presetID
        self.presetDisplayName = presetDisplayName
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.providerClass = providerClass
        self.displayRect = displayRect
        self.phase = phase
    }

    init(
        context: AuthorizedTranslationPresentationContext,
        presetDisplayName: String? = nil,
        resultText: String = "",
        phase: TranslationPresentationPhase = .preparing
    ) {
        self.init(
            sourceText: context.sourceText,
            resultText: resultText,
            presetID: context.presetID,
            presetDisplayName: presetDisplayName,
            sourceLanguage: context.sourceLanguage,
            targetLanguage: context.targetLanguage,
            providerClass: context.providerClass,
            displayRect: context.displayRect,
            phase: phase
        )
    }

    func appending(delta: String) -> Self {
        Self(
            sourceText: sourceText,
            resultText: resultText + delta,
            presetID: presetID,
            presetDisplayName: presetDisplayName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerClass: providerClass,
            displayRect: displayRect,
            phase: .streaming
        )
    }

    func completing(with completion: CompletedTranslation) -> Self {
        Self(
            sourceText: sourceText,
            resultText: completion.resultText,
            presetID: presetID,
            presetDisplayName: presetDisplayName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerClass: providerClass,
            displayRect: displayRect,
            phase: .completed
        )
    }
}

struct ResultPanelActions: Sendable {
    let copy: @MainActor @Sendable () -> Void
    let retry: @MainActor @Sendable () -> Void
    let changePreset: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void

    init(
        copy: @escaping @MainActor @Sendable () -> Void,
        retry: @escaping @MainActor @Sendable () -> Void,
        changePreset: @escaping @MainActor @Sendable () -> Void,
        close: @escaping @MainActor @Sendable () -> Void
    ) {
        self.copy = copy
        self.retry = retry
        self.changePreset = changePreset
        self.close = close
    }
}

@MainActor
protocol ResultPanelPresenting: AnyObject {
    func showTemporary(
        _ presentation: TranslationPresentation,
        actions: ResultPanelActions
    )
    func updateTemporary(_ presentation: TranslationPresentation)
    func dismissTemporary()
    func pinTemporary()
    func dismissPinned()
}

@MainActor
final class ResultPanelController: ResultPanelPresenting {
    @MainActor
    struct Configuration {
        let ordersWindows: Bool
        let installsEventMonitors: Bool
        let visibleFrames: @MainActor () -> [CGRect]
        let pointerLocation: @MainActor () -> CGPoint
        let reduceMotion: @MainActor () -> Bool
        let localeState: AppUILocaleState
        let announcePinnedReplacement: @MainActor (PassiveResultPanel) -> Void

        static let production = Self(
            ordersWindows: true,
            installsEventMonitors: true,
            visibleFrames: { NSScreen.screens.map(\.visibleFrame) },
            pointerLocation: { NSEvent.mouseLocation },
            reduceMotion: {
                if UITestingMode.includes("--ui-testing-reduce-motion") {
                    return true
                }
                if UITestingMode.includes("--ui-testing-standard-motion") {
                    return false
                }
                return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            },
            localeState: .shared,
            announcePinnedReplacement: { panel in
                NSAccessibility.post(
                    element: panel,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: String(
                            localized: "result.pinnedReplaced.announcement",
                            locale: AppUILocaleState.shared.current
                        ),
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ]
                )
            }
        )

        static let testing = Self(
            ordersWindows: false,
            installsEventMonitors: false,
            visibleFrames: { [CGRect(x: 0, y: 0, width: 1_000, height: 800)] },
            pointerLocation: { CGPoint(x: 500, y: 400) },
            reduceMotion: { true },
            localeState: AppUILocaleState(),
            announcePinnedReplacement: { _ in }
        )
    }

    struct DebugSnapshot: Equatable {
        let temporaryCount: Int
        let pinnedCount: Int
        let noticeCount: Int
        let passiveOrderCount: Int
        let clickAwayMonitorInstalled: Bool
        let localClickAwayMonitorInstalled: Bool
        let escapeMonitorInstalled: Bool
    }

    private var temporary: PassiveResultPanel?
    private var pinned: PassiveResultPanel?
    private var clickAwayMonitor: Any?
    private var localClickAwayMonitor: Any?
    private var escapeMonitor: Any?

    private let configuration: Configuration
    private var clickAwayMonitorIsInstalled = false
    private var localClickAwayMonitorIsInstalled = false
    private var escapeMonitorIsInstalled = false
    private var noticeCount = 0
    private var passiveOrderCount = 0

    init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    isolated deinit {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
        }
        if let localClickAwayMonitor {
            NSEvent.removeMonitor(localClickAwayMonitor)
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    func showTemporary(
        _ presentation: TranslationPresentation,
        actions: ResultPanelActions
    ) {
        dismissTemporary()
        guard let placement = PanelPlacementResolver.resolve(
            selection: presentation.displayRect,
            pointer: configuration.pointerLocation(),
            visibleFrames: configuration.visibleFrames()
        ) else { return }

        let panel = PassiveResultPanel(contentRect: placement.frame)
        panel.onDidBecomeKey = { [weak self, weak panel] in
            guard let panel else { return }
            self?.temporaryDidBecomeKey(panel)
        }
        panel.onDidResignKey = { [weak self, weak panel] in
            guard let panel else { return }
            self?.temporaryDidResignKey(panel)
        }
        installContent(
            presentation,
            actions: actions,
            isPinned: false,
            in: panel
        )
        temporary = panel
        installClickAwayMonitorIfNeeded()
        passiveOrderCount += 1
        if configuration.ordersWindows {
            orderFront(panel)
        }
    }

    func updateTemporary(_ presentation: TranslationPresentation) {
        let panel: PassiveResultPanel
        let isPinned: Bool
        if let temporary {
            panel = temporary
            isPinned = false
        } else if let pinned {
            panel = pinned
            isPinned = true
        } else {
            return
        }
        guard let actions = panel.ownerActions else { return }
        installContent(
            presentation,
            actions: actions,
            isPinned: isPinned,
            in: panel
        )
    }

    func dismissTemporary() {
        rawDismissTemporary()
    }

    private func rawDismissTemporary() {
        removeClickAwayMonitor()
        removeEscapeMonitor()
        temporary?.close()
        temporary = nil
    }

    func pinTemporary() {
        guard let panel = temporary else { return }
        removeClickAwayMonitor()
        removeEscapeMonitor()
        temporary = nil

        if let oldPinned = pinned {
            noticeCount += 1
            configuration.announcePinnedReplacement(oldPinned)
            let actions = oldPinned.ownerActions
            rawDismissPinned()
            actions?.close()
        }
        pinned = panel
        panel.beginInteraction(makeKey: configuration.ordersWindows)
        if let presentation = panel.presentation,
           let actions = panel.ownerActions {
            installContent(
                presentation,
                actions: actions,
                isPinned: true,
                in: panel
            )
        }
        animateReplacementIfNeeded(panel)
    }

    func dismissPinned() {
        rawDismissPinned()
    }

    private func rawDismissPinned() {
        pinned?.close()
        pinned = nil
    }

    func dismissAll() {
        dismissTemporary()
        dismissPinned()
    }

    var plaintextPresentationCount: Int {
        [temporary, pinned].compactMap { $0?.presentation }.filter {
            !$0.sourceText.isEmpty || !$0.resultText.isEmpty
        }.count
    }

    private func installContent(
        _ presentation: TranslationPresentation,
        actions: ResultPanelActions,
        isPinned: Bool,
        in panel: PassiveResultPanel
    ) {
        panel.ownerActions = actions
        let contextualActions = ResultPanelActions(
            copy: actions.copy,
            retry: actions.retry,
            changePreset: actions.changePreset,
            close: { [weak self, weak panel] in
                guard let self, let panel else { return }
                if isPinned {
                    self.dismissPinned(panel)
                } else {
                    self.dismissTemporary(panel)
                }
                actions.close()
            }
        )
        panel.presentation = presentation
        panel.resultActions = contextualActions
        let reduceMotion = configuration.reduceMotion()
        panel.contentView = NSHostingView(
            rootView: ResultPanelView(
                presentation: presentation,
                isPinned: isPinned,
                actions: contextualActions,
                pin: { [weak self] in self?.pinTemporary() },
                reduceMotionOverride: reduceMotion,
                localeState: configuration.localeState
            )
        )
    }

    private func orderFront(_ panel: PassiveResultPanel) {
        guard !configuration.reduceMotion() else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotionPolicy.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func animateReplacementIfNeeded(_ panel: PassiveResultPanel) {
        guard configuration.ordersWindows, !configuration.reduceMotion() else { return }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotionPolicy.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func installClickAwayMonitorIfNeeded() {
        guard !clickAwayMonitorIsInstalled else { return }
        clickAwayMonitorIsInstalled = true
        localClickAwayMonitorIsInstalled = true
        guard configuration.installsEventMonitors else { return }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let location = event.locationInWindow
            Task { @MainActor [weak self] in
                self?.handleClickAway(at: location)
            }
        }
        localClickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let location: CGPoint
            if let window = event.window {
                location = window.convertPoint(toScreen: event.locationInWindow)
            } else {
                location = NSEvent.mouseLocation
            }
            self?.handleClickAway(at: location)
            return event
        }
    }

    private func temporaryDidBecomeKey(_ panel: PassiveResultPanel) {
        guard temporary === panel, panel.interactionEnabled else { return }
        installEscapeMonitorIfNeeded()
    }

    private func temporaryDidResignKey(_ panel: PassiveResultPanel) {
        guard temporary === panel else { return }
        removeEscapeMonitor()
    }

    private func installEscapeMonitorIfNeeded() {
        guard !escapeMonitorIsInstalled else { return }
        escapeMonitorIsInstalled = true
        guard configuration.installsEventMonitors else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.temporary?.resultActions?.close()
            return nil
        }
    }

    private func handleClickAway(at screenPoint: CGPoint) {
        guard let temporary, !temporary.frame.contains(screenPoint) else { return }
        temporary.resultActions?.close()
    }

    private func dismissTemporary(_ panel: PassiveResultPanel) {
        guard temporary === panel else { return }
        rawDismissTemporary()
    }

    private func dismissPinned(_ panel: PassiveResultPanel) {
        guard pinned === panel else { return }
        rawDismissPinned()
    }

    private func removeClickAwayMonitor() {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
        }
        clickAwayMonitor = nil
        clickAwayMonitorIsInstalled = false
        if let localClickAwayMonitor {
            NSEvent.removeMonitor(localClickAwayMonitor)
        }
        localClickAwayMonitor = nil
        localClickAwayMonitorIsInstalled = false
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
        escapeMonitorIsInstalled = false
    }

    var debugSnapshot: DebugSnapshot {
        DebugSnapshot(
            temporaryCount: temporary == nil ? 0 : 1,
            pinnedCount: pinned == nil ? 0 : 1,
            noticeCount: noticeCount,
            passiveOrderCount: passiveOrderCount,
            clickAwayMonitorInstalled: clickAwayMonitorIsInstalled,
            localClickAwayMonitorInstalled: localClickAwayMonitorIsInstalled,
            escapeMonitorInstalled: escapeMonitorIsInstalled
        )
    }

    var debugTemporaryPanel: PassiveResultPanel? { temporary }
    var debugPinnedPanel: PassiveResultPanel? { pinned }

    func debugBeginTemporaryInteraction() {
        guard let temporary else { return }
        temporary.beginInteraction(makeKey: false)
        temporaryDidBecomeKey(temporary)
    }

    func debugTemporaryDidResignKey() {
        guard let temporary else { return }
        temporaryDidResignKey(temporary)
    }

    func debugHandleLocalMouseDown(at screenPoint: CGPoint) {
        guard localClickAwayMonitorIsInstalled else { return }
        handleClickAway(at: screenPoint)
    }

    func debugPressEscape() {
        guard escapeMonitorIsInstalled else { return }
        temporary?.resultActions?.close()
    }

    func debugClickAway() {
        guard clickAwayMonitorIsInstalled else { return }
        temporary?.resultActions?.close()
    }
}
