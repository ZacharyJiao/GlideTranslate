import AppKit
import SharedSupport
import SwiftUI

struct ResultPanelView: View {
    let model: ResultPanelPresentationModel
    let actions: ResultPanelActions
    let pin: @MainActor @Sendable () -> Void
    let sourceExpansionChanged: (@MainActor @Sendable () -> Void)?
    let reduceMotionOverride: Bool?
    let localeState: AppUILocaleState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        model: ResultPanelPresentationModel,
        actions: ResultPanelActions,
        pin: @escaping @MainActor @Sendable () -> Void,
        sourceExpansionChanged: (@MainActor @Sendable () -> Void)? = nil,
        reduceMotionOverride: Bool? = nil,
        localeState: AppUILocaleState = .shared
    ) {
        self.model = model
        self.actions = actions
        self.pin = pin
        self.sourceExpansionChanged = sourceExpansionChanged
        self.reduceMotionOverride = reduceMotionOverride
        self.localeState = localeState
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlideVisualTokens.panelSpacing) {
            header
            sourceSection

            Text("result.output.heading")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("result-output-heading")

            VStack(alignment: .trailing, spacing: 4) {
                SafeRenderedOutput(
                    text: model.presentation.resultText,
                    latestScrollRequest: model.latestScrollRequest,
                    onMetrics: { [weak model] viewport, content, offset in
                        model?.updateScrollState(
                            viewportHeight: viewport,
                            contentHeight: content,
                            offsetFromBottom: offset
                        )
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity)
                .accessibilityIdentifier("result-output")

                if model.showsBackToLatest {
                    Button {
                        model.backToLatest()
                    } label: {
                        Label(
                            "result.backToLatest",
                            systemImage: "arrow.down.to.line"
                        )
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("result-back-to-latest")
                }
            }

            metadata
            actionBar
        }
        .padding(GlideVisualTokens.panelPadding)
        .frame(minHeight: PanelSizingPolicy.minimumHeight)
        .background { panelBackground }
        .overlay {
            RoundedRectangle(cornerRadius: GlideVisualTokens.panelCornerRadius)
                .strokeBorder(
                    GlideVisualTokens.primaryInk.opacity(
                        surfaceStyle == .increasedContrast ? 0.72 : 0.16
                    ),
                    lineWidth: surfaceStyle == .increasedContrast ? 2 : 1
                )
        }
        .transition(PanelMotionPolicy.transition(reduceMotion: reduceMotion))
        .animation(
            PanelMotionPolicy.animation(reduceMotion: reduceMotion),
            value: model.presentation.phase
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result-panel")
        .environment(\.locale, localeState.current)
        .overlay(alignment: .topLeading) {
            if UITestingMode.isEnabled {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(
                        reduceMotion
                            ? Text("result.motion.reduced")
                            : Text("result.motion.standard")
                    )
                    .accessibilityIdentifier(
                        reduceMotion
                            ? "result-motion-reduced"
                            : "result-motion-standard"
                    )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let presetDisplayName = model.presentation.presetDisplayName {
                Text(verbatim: presetDisplayName)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text(LocalizedStringKey(
                    model.presentation.presetID.safeDisplayLocalizationKey
                ))
                .font(.headline)
                .lineLimit(1)
            }
            Spacer()
            Text(LocalizedStringKey(model.presentation.phase.localizationKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("result-model-status")
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.presentation.sourceText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(model.isSourceExpanded ? nil : 2)
                .accessibilityLabel("result.source.accessibility")
                .accessibilityValue(model.presentation.sourceText)
                .accessibilityIdentifier("result-source")

            Button {
                model.toggleSourceExpansion()
                sourceExpansionChanged?()
            } label: {
                Label(
                    model.isSourceExpanded
                        ? "result.source.collapse"
                        : "result.source.expand",
                    systemImage: model.isSourceExpanded
                        ? "chevron.up"
                        : "chevron.down"
                )
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .accessibilityIdentifier("result-source-disclosure")
        }
    }

    private var surfaceStyle: PanelSurfaceStyle {
        PanelSurfaceStyle.resolve(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: GlideVisualTokens.panelCornerRadius
        )
        switch surfaceStyle {
        case .standard:
            shape.fill(.regularMaterial)
        case .reducedTransparency, .increasedContrast:
            shape.fill(GlideVisualTokens.elevatedSurface)
        }
    }

    private var metadata: some View {
        HStack(spacing: GlideVisualTokens.compactSpacing) {
            Label {
                languageText(model.presentation.sourceLanguage)
                Text("→")
                languageText(model.presentation.targetLanguage)
            } icon: {
                Image(systemName: "character.book.closed")
            }
            Spacer()
            Label {
                Text(LocalizedStringKey(
                    model.presentation.providerClass.localizationKey
                ))
            } icon: {
                Image(systemName: model.presentation.providerClass.symbolName)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var actionBar: some View {
        HStack(spacing: GlideVisualTokens.compactSpacing) {
            Button("result.copy", action: actions.copy)
                .keyboardShortcut("c", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(GlideVisualTokens.actionEmerald)
                .accessibilityIdentifier("result-copy")
            Button("result.retry", action: actions.retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("result-retry")

            if model.actionLayout == .compactOverflow {
                Menu {
                    Button("result.changePreset", action: actions.changePreset)
                } label: {
                    Label("result.changePreset", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("result-change-preset")
            } else {
                Button("result.changePreset", action: actions.changePreset)
                    .accessibilityIdentifier("result-change-preset")
            }

            Spacer()
            if !model.isPinned {
                iconButton(
                    systemName: "pin",
                    label: "result.pin",
                    action: pin,
                    identifier: "result-pin"
                )
            }
            iconButton(
                systemName: "xmark",
                label: "result.close",
                action: actions.close,
                identifier: "result-close"
            )
        }
        .controlSize(.small)
    }

    private func iconButton(
        systemName: String,
        label: LocalizedStringKey,
        action: @escaping @MainActor @Sendable () -> Void,
        identifier: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 28, minHeight: 28)
        .accessibilityLabel(label)
        .help(label)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func languageText(_ language: LanguageChoice) -> some View {
        switch language {
        case .automatic:
            Text("language.automatic")
        case let .identified(identifier):
            Text(verbatim: identifier)
        }
    }
}

private struct SafeRenderedOutput: NSViewRepresentable {
    let text: String
    let latestScrollRequest: Int
    let onMetrics: (@MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onMetrics: onMetrics)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.installBoundsObserver()
        updateText(in: scrollView)
        context.coordinator.reportMetrics()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onMetrics = onMetrics
        updateText(in: scrollView)
        context.coordinator.scrollToLatestIfRequested(latestScrollRequest)
        context.coordinator.reportMetrics()
    }

    private func updateText(in scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let rendered = SafeMarkdownRenderer().render(
            SafeMarkdownParser().parse(text)
        )
        guard textView.attributedString() != rendered else { return }

        let priorSelection = textView.selectedRanges
        let priorOrigin = scrollView.contentView.bounds.origin
        let wasNearBottom = max(
            0,
            textView.bounds.height - scrollView.contentView.bounds.maxY
        ) <= 24
        textView.textStorage?.setAttributedString(rendered)
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        if wasNearBottom {
            let end = max(0, textView.string.utf16.count)
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        } else {
            scrollView.contentView.setBoundsOrigin(priorOrigin)
        }
        let maximumLocation = textView.string.utf16.count
        textView.selectedRanges = priorSelection.map { range in
            let range = range.rangeValue
            let location = min(max(0, range.location), maximumLocation)
            let length = min(range.length, maximumLocation - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        var onMetrics: (@MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void)?
        private var boundsObserver: NSObjectProtocol?
        private var lastScrollRequest = 0

        init(
            onMetrics: (@MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void)?
        ) {
            self.onMetrics = onMetrics
        }

        func installBoundsObserver() {
            guard boundsObserver == nil, let scrollView else { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reportMetrics()
                }
            }
        }

        func reportMetrics() {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            let contentHeight = documentView.bounds.height
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let offsetFromBottom = max(0, contentHeight - visibleMaxY)
            onMetrics?(viewportHeight, contentHeight, offsetFromBottom)
        }

        func scrollToLatestIfRequested(_ request: Int) {
            guard request != lastScrollRequest else { return }
            lastScrollRequest = request
            guard let textView = scrollView?.documentView as? NSTextView else { return }
            let end = max(0, textView.string.utf16.count)
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }

        isolated deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}

extension TranslationPresentationPhase {
    var localizationKey: String {
        switch self {
        case .preparing: "result.phase.preparing"
        case .connecting: "result.phase.connecting"
        case .waitingForFirstToken: "result.phase.waiting"
        case .streaming: "result.phase.streaming"
        case .completed: "result.phase.completed"
        case .failed: "result.phase.failed"
        }
    }
}

private extension DestinationPrivacyClass {
    var symbolName: String {
        switch self {
        case .localOnDevice: "desktopcomputer"
        case .localNetwork: "network"
        case .cloud: "cloud"
        case .unresolvedOrChanged: "exclamationmark.triangle"
        }
    }
}
