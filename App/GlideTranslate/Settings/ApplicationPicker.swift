import AppKit
import SharedSupport
import UniformTypeIdentifiers

@MainActor
protocol ApplicationChoosing {
    func chooseApplication() -> ApplicationIdentity?
}

@MainActor
struct SystemApplicationChooser: ApplicationChoosing {
    func chooseApplication() -> ApplicationIdentity? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.applicationIdentity(at: url)
    }

    static func applicationIdentity(at url: URL) -> ApplicationIdentity? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return nil
        }
        let displayName = ["CFBundleDisplayName", "CFBundleName"]
            .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        guard !displayName.isEmpty else { return nil }
        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }
}
