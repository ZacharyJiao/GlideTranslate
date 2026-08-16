import AppKit
import SharedSupport
import SwiftUI

struct ResultPanelView: View {
    let presentation: TranslationPresentation
    let isPinned: Bool
    let actions: ResultPanelActions
    let pin: @MainActor @Sendable () -> Void
    let reduceMotionOverride: Bool?
    let localeState: AppUILocaleState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(
        presentation: TranslationPresentation,
        isPinned: Bool,
        actions: ResultPanelActions,
        pin: @escaping @MainActor @Sendable () -> Void,
        reduceMotionOverride: Bool? = nil,
        localeState: AppUILocaleState = .shared
    ) {
        self.presentation = presentation
        self.isPinned = isPinned
        self.actions = actions
        self.pin = pin
        self.reduceMotionOverride = reduceMotionOverride
        self.localeState = localeState
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let presetDisplayName = presentation.presetDisplayName {
                    Text(verbatim: presetDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    Text(LocalizedStringKey(presentation.presetID.safeDisplayLocalizationKey))
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Text(LocalizedStringKey(presentation.phase.localizationKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("result-model-status")
            }

            Text(presentation.sourceText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .accessibilityLabel("result.source.accessibility")
                .accessibilityValue(presentation.sourceText)
                .accessibilityIdentifier("result-source")

            Text("result.output.heading")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("result-output-heading")

            SafeRenderedOutput(text: presentation.resultText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("result-output")

            HStack(spacing: 8) {
                Label {
                    languageText(presentation.sourceLanguage)
                    Text("→")
                    languageText(presentation.targetLanguage)
                } icon: {
                    Image(systemName: "character.book.closed")
                }
                Spacer()
                Label {
                    Text(LocalizedStringKey(presentation.providerClass.localizationKey))
                } icon: {
                    Image(systemName: presentation.providerClass.symbolName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("result.copy", action: actions.copy)
                    .keyboardShortcut("c", modifiers: .command)
                    .accessibilityIdentifier("result-copy")
                Button("result.retry", action: actions.retry)
                    .accessibilityIdentifier("result-retry")
                Button("result.changePreset", action: actions.changePreset)
                    .accessibilityIdentifier("result-change-preset")
                Spacer()
                if !isPinned {
                    Button("result.pin", action: pin)
                        .accessibilityIdentifier("result-pin")
                }
                Button("result.close", action: actions.close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("result-close")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 180)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(PanelMotionPolicy.transition(reduceMotion: reduceMotion))
        .animation(
            PanelMotionPolicy.animation(reduceMotion: reduceMotion),
            value: presentation.phase
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(
            SafeMarkdownRenderer().render(SafeMarkdownParser().parse(text))
        )
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
