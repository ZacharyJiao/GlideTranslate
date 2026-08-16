import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("about.version", value: version)
                .accessibilityIdentifier("about.version")
            Text("about.licenses.localNotices")
                .accessibilityIdentifier("about.licenses")
            Text("about.privacy.summary")
                .accessibilityIdentifier("about.privacy")
            Button("about.source.unavailable") {}
                .disabled(true)
                .accessibilityIdentifier("about.source")
            Button("about.releases.unavailable") {}
                .disabled(true)
                .accessibilityIdentifier("about.releases")
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return "\(version) (\(build))"
    }
}
