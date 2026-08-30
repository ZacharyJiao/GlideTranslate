import AppKit
import SwiftUI

struct GlidePageHeader: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GlideStatusSurface: View {
    let message: LocalizedStringKey
    let nextAction: LocalizedStringKey?
    var systemImage = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(GlideVisualTokens.actionEmerald)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout.weight(.medium))
                if let nextAction {
                    Text(nextAction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            GlideVisualTokens.elevatedSurface,
            in: RoundedRectangle(
                cornerRadius: GlideVisualTokens.sectionCornerRadius
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: GlideVisualTokens.sectionCornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }
}

struct GlideWindowChrome: NSViewRepresentable {
    let minimumSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: view.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert([.fullSizeContentView, .resizable])
        window.minSize = minimumSize
    }
}
