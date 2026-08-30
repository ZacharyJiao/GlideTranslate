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
        let observesScreenChanges: Bool
        let displays: @MainActor () -> [PanelDisplay]
        let pointerLocation: @MainActor () -> CGPoint
        let reduceMotion: @MainActor () -> Bool
        let measurement: @MainActor (
            TranslationPresentation,
            NSAppearance?
        ) -> PanelRenderedMeasurement?
        let schedulesResizeDelivery: Bool
        let localeState: AppUILocaleState
        let announcePinnedReplacement: @MainActor (PassiveResultPanel) -> Void

        static let production = Self(
            ordersWindows: true,
            installsEventMonitors: true,
            observesScreenChanges: true,
            displays: {
                NSScreen.screens.enumerated().map { index, screen in
                    let screenNumber = screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                    ] as? NSNumber
                    return PanelDisplay(
                        id: screenNumber?.stringValue ?? "screen-\(index)",
                        visibleFrame: screen.visibleFrame
                    )
                }
            },
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
            measurement: PanelContentMeasurer.measure,
            schedulesResizeDelivery: true,
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

        static var testing: Self { testing() }

        static func testing(
            displays: (@MainActor () -> [PanelDisplay])? = nil,
            pointer: @escaping @MainActor () -> CGPoint = {
                CGPoint(x: 500, y: 400)
            },
            visibleFrames: (@MainActor () -> [CGRect])? = nil,
            measurement: @escaping @MainActor (
                TranslationPresentation,
                NSAppearance?
            ) -> PanelRenderedMeasurement? = PanelContentMeasurer.measure
        ) -> Self {
            let resolvedDisplays: @MainActor () -> [PanelDisplay]
            if let displays {
                resolvedDisplays = displays
            } else if let visibleFrames {
                resolvedDisplays = {
                    visibleFrames().enumerated().map {
                        PanelDisplay(
                            id: "display-\($0.offset)",
                            visibleFrame: $0.element
                        )
                    }
                }
            } else {
                resolvedDisplays = {
                    [
                        PanelDisplay(
                            id: "display-0",
                            visibleFrame: CGRect(
                                x: 0,
                                y: 0,
                                width: 1_000,
                                height: 800
                            )
                        )
                    ]
                }
            }
            return Self(
                ordersWindows: false,
                installsEventMonitors: false,
                observesScreenChanges: false,
                displays: resolvedDisplays,
                pointerLocation: pointer,
                reduceMotion: { true },
                measurement: measurement,
                schedulesResizeDelivery: false,
                localeState: AppUILocaleState(),
                announcePinnedReplacement: { _ in }
            )
        }
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
    private var screenParametersObserver: NSObjectProtocol?

    private let configuration: Configuration
    private var clickAwayMonitorIsInstalled = false
    private var localClickAwayMonitorIsInstalled = false
    private var escapeMonitorIsInstalled = false
    private var noticeCount = 0
    private var passiveOrderCount = 0

    init(configuration: Configuration = .production) {
        self.configuration = configuration
        if configuration.observesScreenChanges {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreenParametersChanged()
                }
            }
        }
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
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func showTemporary(
        _ presentation: TranslationPresentation,
        actions: ResultPanelActions
    ) {
        dismissTemporary()
        guard var placement = PanelPlacementResolver.resolve(
            selection: presentation.displayRect,
            pointer: configuration.pointerLocation(),
            displays: configuration.displays(),
            panelSize: PanelSizingPolicy.initialSize
        ) else { return }

        if let display = configuration.displays().first(where: {
            $0.id == placement.displayID
        }) {
            let safeInitialSize = CGSize(
                width: min(
                    PanelSizingPolicy.initialSize.width,
                    max(1, display.visibleFrame.width
                        - PanelSizingPolicy.widthSafetyMargin)
                ),
                height: min(
                    PanelSizingPolicy.initialSize.height,
                    display.visibleFrame.height
                )
            )
            if safeInitialSize != placement.frame.size,
               let safePlacement = PanelPlacementResolver.resolve(
                   selection: presentation.displayRect,
                   pointer: configuration.pointerLocation(),
                   displays: configuration.displays(),
                   panelSize: safeInitialSize,
                   preferredSide: placement.side,
                   preferredPointerCorner: placement.pointerCorner
               ) {
                placement = safePlacement
            }
        }

        let panel = PassiveResultPanel(contentRect: placement.frame)
        panel.updatePlacement(placement)
        panel.onUserResize = { [weak self, weak panel] size in
            guard let self, let panel,
                  let model = panel.presentationModel,
                  let display = self.display(for: panel) else { return }
            let requested = CGRect(origin: panel.frame.origin, size: size)
            let constrained = requested.clamped(to: display.visibleFrame)
            if constrained != panel.frame {
                panel.applyConstrainedManualFrame(constrained)
            }
            panel.updatePlacement(
                PanelPlacement(
                    frame: constrained,
                    displayIndex: self.index(of: display.id),
                    displayID: display.id,
                    reason: .clamped,
                    side: panel.placement.side,
                    pointerCorner: panel.placement.pointerCorner
                )
            )
            _ = model.applyManualResize(constrained.size)
        }
        panel.onDidBecomeKey = { [weak self, weak panel] in
            guard let panel else { return }
            self?.temporaryDidBecomeKey(panel)
        }
        panel.onDidResignKey = { [weak self, weak panel] in
            guard let panel else { return }
            self?.temporaryDidResignKey(panel)
        }
        panel.anchorRect = presentation.displayRect
        panel.anchorPointer = configuration.pointerLocation()
        installInitialContent(
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
        guard panel.ownerActions != nil else { return }
        guard let model = panel.presentationModel else { return }
        model.isPinned = isPinned
        model.updatePresentation(presentation)
        panel.presentation = model.presentation
        resizePanelIfNeeded(panel, presentation: panel.presentation ?? presentation)
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
        if let display = display(for: panel) {
            panel.configurePinnedResizing(visibleFrame: display.visibleFrame)
        }
        panel.beginInteraction(makeKey: configuration.ordersWindows)
        panel.presentationModel?.isPinned = true
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

    private func installInitialContent(
        _ presentation: TranslationPresentation,
        actions: ResultPanelActions,
        isPinned: Bool,
        in panel: PassiveResultPanel
    ) {
        panel.ownerActions = actions
        let model = ResultPanelPresentationModel(
            presentation: presentation,
            isPinned: isPinned,
            initialSize: panel.frame.size
        )
        panel.presentationModel = model
        panel.presentation = model.presentation

        panel.resultActions = ResultPanelActions(
            copy: actions.copy,
            retry: actions.retry,
            changePreset: actions.changePreset,
            close: { [weak self, weak panel, weak model] in
                guard let self, let panel else { return }
                if model?.isPinned == true {
                    self.dismissPinned(panel)
                } else {
                    self.dismissTemporary(panel)
                }
                actions.close()
            }
        )
        guard let contextualActions = panel.resultActions else { return }
        let rootView = ResultPanelView(
            model: model,
            actions: contextualActions,
            pin: { [weak self] in self?.pinTemporary() },
            sourceExpansionChanged: { [weak self, weak panel, weak model] in
                guard let self, let panel, let model else { return }
                self.resizePanelIfNeeded(
                    panel,
                    presentation: model.presentation
                )
            },
            reduceMotionOverride: configuration.reduceMotion(),
            localeState: configuration.localeState
        )
        panel.contentView = NSHostingView(rootView: rootView)
    }

    private func resizePanelIfNeeded(
        _ panel: PassiveResultPanel,
        presentation: TranslationPresentation
    ) {
        guard let model = panel.presentationModel,
              model.automaticSizingEnabled,
              let display = display(for: panel) else { return }

        let measurement = configuration.measurement(
            presentation,
            panel.effectiveAppearance
        ) ?? PanelRenderedMeasurement(
            collapsedHeights: [:],
            expandedHeights: [:]
        )
        let decision = PanelSizingPolicy.targetSize(
            for: measurement,
            constraints: PanelSizingConstraints(
                visibleFrame: display.visibleFrame,
                availableAnchorSpace: availableAnchorSpace(
                    for: panel,
                    visibleFrame: display.visibleFrame
                )
            ),
            sourceExpanded: model.isSourceExpanded
        )
        let now = CACurrentMediaTime()
        guard model.applySizingDecision(decision, at: now) else {
            schedulePendingResizeIfNeeded(panel)
            return
        }
        setPanelFrame(
            panel,
            size: model.automaticSize,
            visibleFrame: display.visibleFrame
        )
    }

    private func schedulePendingResizeIfNeeded(_ panel: PassiveResultPanel) {
        guard configuration.schedulesResizeDelivery,
              panel.pendingResizeTask == nil,
              panel.presentationModel?.pendingSizingDecision != nil else { return }
        panel.pendingResizeTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let panel else { return }
            panel.pendingResizeTask = nil
            guard !Task.isCancelled,
                  let self,
                  let model = panel.presentationModel,
                  let display = self.display(for: panel) else { return }
            guard model.flushPendingSizing(at: CACurrentMediaTime()) else {
                return
            }
            self.setPanelFrame(
                panel,
                size: model.automaticSize,
                visibleFrame: display.visibleFrame
            )
        }
    }

    private func display(for panel: PassiveResultPanel) -> PanelDisplay? {
        let displays = configuration.displays().filter {
            $0.visibleFrame.isFiniteAndUsable
        }
        if let currentIndex = displays.firstIndex(where: {
            $0.id == panel.placement.displayID
        }) {
            let current = displays[currentIndex]
            if panel.placement.displayIndex != currentIndex {
                panel.updatePlacement(
                    PanelPlacement(
                        frame: panel.frame,
                        displayIndex: currentIndex,
                        displayID: current.id,
                        reason: panel.placement.reason,
                        side: panel.placement.side,
                        pointerCorner: panel.placement.pointerCorner
                    )
                )
            }
            return current
        }
        guard let replacement = PanelPlacementResolver.resolve(
            selection: panel.anchorRect,
            pointer: panel.anchorPointer,
            displays: displays,
            panelSize: panel.frame.size,
            preferredSide: panel.placement.side,
            preferredPointerCorner: panel.placement.pointerCorner
        ) else { return nil }
        panel.updatePlacement(replacement)
        return displays.first(where: { $0.id == replacement.displayID })
    }

    private func index(of displayID: String) -> Int {
        configuration.displays().firstIndex(where: { $0.id == displayID }) ?? 0
    }

    private func availableAnchorSpace(
        for panel: PassiveResultPanel,
        visibleFrame: CGRect
    ) -> CGFloat {
        switch panel.placement.side {
        case .below:
            guard let anchor = panel.anchorRect else { return visibleFrame.height }
            return max(1, anchor.minY - visibleFrame.minY - PanelPlacementResolver.defaultGap)
        case .above:
            guard let anchor = panel.anchorRect else { return visibleFrame.height }
            return max(1, visibleFrame.maxY - anchor.maxY - PanelPlacementResolver.defaultGap)
        case .pointer:
            switch panel.placement.pointerCorner ?? .topLeft {
            case .topLeft, .topRight:
                return max(
                    1,
                    panel.anchorPointer.y
                        - visibleFrame.minY
                        - PanelPlacementResolver.defaultGap
                )
            case .bottomLeft, .bottomRight:
                return max(
                    1,
                    visibleFrame.maxY
                        - panel.anchorPointer.y
                        - PanelPlacementResolver.defaultGap
                )
            }
        }
    }

    private func setPanelFrame(
        _ panel: PassiveResultPanel,
        size: CGSize,
        visibleFrame: CGRect
    ) {
        let oldFrame = panel.frame
        var frame = CGRect(origin: oldFrame.origin, size: size)
        switch panel.placement.side {
        case .below:
            if let anchor = panel.anchorRect {
                frame.origin.y = anchor.minY
                    - PanelPlacementResolver.defaultGap
                    - frame.height
            }
        case .above:
            if let anchor = panel.anchorRect {
                frame.origin.y = anchor.maxY + PanelPlacementResolver.defaultGap
            }
        case .pointer:
            frame = PanelPlacementResolver.frame(
                size: size,
                pointer: panel.anchorPointer,
                corner: panel.placement.pointerCorner ?? .topLeft
            )
        }
        let clamped = frame.clamped(to: visibleFrame)
        let updatedPlacement = PanelPlacement(
            frame: clamped,
            displayIndex: panel.placement.displayIndex,
            displayID: panel.placement.displayID,
            reason: panel.placement.reason,
            side: panel.placement.side,
            pointerCorner: panel.placement.pointerCorner
        )
        panel.updatePlacement(updatedPlacement)
        guard oldFrame != clamped else { return }
        panel.applyAutomaticFrame(
            clamped,
            animated: !configuration.reduceMotion() && configuration.ordersWindows,
            duration: GlideMotionTokens.resizeDuration
        )
    }

    private func handleScreenParametersChanged() {
        for panel in [temporary, pinned].compactMap({ $0 }) {
            guard let display = display(for: panel) else { continue }
            let reclamped = panel.frame.clamped(to: display.visibleFrame)
            panel.updatePlacement(
                PanelPlacement(
                    frame: reclamped,
                    displayIndex: index(of: display.id),
                    displayID: display.id,
                    reason: reclamped == panel.frame
                        ? panel.placement.reason
                        : .clamped,
                    side: panel.placement.side,
                    pointerCorner: panel.placement.pointerCorner
                )
            )
            if reclamped != panel.frame {
                panel.applyAutomaticFrame(reclamped, animated: false)
                panel.presentationModel?.reclampAutomaticSize(reclamped.size)
            }
            if panel.presentationModel?.isPinned == true {
                panel.configurePinnedResizing(visibleFrame: display.visibleFrame)
            }
        }
    }

    private func orderFront(_ panel: PassiveResultPanel) {
        guard !configuration.reduceMotion() else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        let finalFrame = panel.frame
        let offset = PanelMotionPolicy.entryOffset(
            side: panel.placement.side,
            pointerCorner: panel.placement.pointerCorner
        )
        let initialFrame = finalFrame.offsetBy(
            dx: offset.width,
            dy: offset.height
        )
        panel.alphaValue = 0
        panel.applyAutomaticFrame(initialFrame, animated: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotionPolicy.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: false)
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

    func debugScreenParametersChanged() {
        handleScreenParametersChanged()
    }
}
