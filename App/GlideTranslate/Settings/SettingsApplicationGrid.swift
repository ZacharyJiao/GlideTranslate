import AppKit
import SharedSupport
import SwiftUI

enum SettingsApplicationGridLayout {
    static let minimumCardWidth: CGFloat = 200
    static let spacing: CGFloat = 8

    static func columnCount(availableWidth: CGFloat) -> Int {
        max(1, Int((availableWidth + spacing) / (minimumCardWidth + spacing)))
    }
}

struct SettingsApplicationGrid<Trailing: View>: View {
    let applications: [ApplicationIdentity]
    @ViewBuilder let trailing: (ApplicationIdentity) -> Trailing

    var body: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(
                    minimum: SettingsApplicationGridLayout.minimumCardWidth,
                    maximum: 280
                ),
                spacing: SettingsApplicationGridLayout.spacing,
                alignment: .leading
            )],
            alignment: .leading,
            spacing: SettingsApplicationGridLayout.spacing
        ) {
            ForEach(applications, id: \.bundleIdentifier) { application in
                HStack(spacing: 9) {
                    SettingsApplicationIcon(bundleIdentifier: application.bundleIdentifier)
                    Text(verbatim: application.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing(application)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct SettingsApplicationIcon: View {
    let bundleIdentifier: String

    var body: some View {
        Group {
            if let icon = SystemApplicationIconStore.icon(for: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum SystemApplicationIconStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleIdentifier: String) -> NSImage? {
        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
