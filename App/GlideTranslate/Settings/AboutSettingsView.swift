import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("app.name")
                    .font(.largeTitle.weight(.semibold))
            }
            LabeledContent("about.version", value: version)
                .accessibilityIdentifier("about.version")
            Divider()
            Label("about.privacy.summary", systemImage: "hand.raised.fill")
                .accessibilityIdentifier("about.privacy")
            Label("about.licenses.localNotices", systemImage: "doc.text")
                .accessibilityIdentifier("about.licenses")
            HStack(spacing: 16) {
                Link("about.source", destination: sourceURL)
                    .accessibilityIdentifier("about.source")
                Link("about.releases", destination: releasesURL)
                    .accessibilityIdentifier("about.releases")
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(24)
        .background(
            GlideVisualTokens.elevatedSurface,
            in: RoundedRectangle(cornerRadius: GlideVisualTokens.sectionCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GlideVisualTokens.sectionCornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var sourceURL: URL {
        URL(string: "https://github.com/ZacharyJiao/GlideTranslate")!
    }

    private var releasesURL: URL {
        sourceURL.appending(path: "releases")
    }
}
