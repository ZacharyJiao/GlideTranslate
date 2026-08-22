import SwiftUI

@MainActor
struct SelectionSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    private let applicationChooser: any ApplicationChoosing

    init(
        viewModel: SettingsViewModel,
        applicationChooser: any ApplicationChoosing = SystemApplicationChooser()
    ) {
        self.viewModel = viewModel
        self.applicationChooser = applicationChooser
    }

    var body: some View {
        Form {
            Section("selection.accessibility") {
                Text(LocalizedStringKey(
                    "selection.accessibility.status.\(viewModel.accessibilityStatus.rawValue)"
                ))
                HStack {
                    Button("selection.accessibility.refresh") {
                        viewModel.refreshAccessibilityStatus()
                    }
                    Button("selection.accessibility.openSettings") {
                        viewModel.openAccessibilitySettings()
                    }
                    .accessibilityHint("selection.accessibility.openSettings.hint")
                    Button("selection.accessibility.enable") {
                        viewModel.requestAccessibility()
                    }
                    .accessibilityHint("selection.accessibility.enable.hint")
                }
            }
            .accessibilityIdentifier("selection.accessibility")

            Section("selection.applications") {
                if viewModel.snapshot.generalAutomaticApplications.isEmpty {
                    Text("selection.applications.none")
                }
                ForEach(
                    viewModel.snapshot.generalAutomaticApplications.sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    },
                    id: \.bundleIdentifier
                ) { application in
                    HStack {
                        LabeledContent(application.displayName, value: application.bundleIdentifier)
                        Button("selection.applications.remove") {
                            viewModel.performOwned {
                                await $0.removeGeneralApplication(application)
                            }
                        }
                        .accessibilityHint("selection.applications.remove.hint")
                    }
                }
                Button("selection.applications.add") {
                    guard let application = applicationChooser.chooseApplication() else {
                        return
                    }
                    viewModel.performOwned { model in
                        await model.addGeneralApplication(
                            bundleIdentifier: application.bundleIdentifier,
                            displayName: application.displayName
                        )
                    }
                }
                .accessibilityIdentifier("selection.applications.add")
                if viewModel.snapshot.generalAutomaticApplications.contains(where: {
                    $0.bundleIdentifier == "com.microsoft.VSCode"
                }) {
                    Text("selection.applications.vscode.accessibilityNote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(
                        destination: URL(string: "vscode://settings/editor.accessibilitySupport")!
                    ) {
                        Text("selection.applications.vscode.openSettings")
                    }
                }
            }
            .accessibilityIdentifier("selection.applications")

            Toggle("selection.mouse", isOn: mouseEnabled)
                .accessibilityIdentifier("selection.mouse")
            Toggle("selection.keyboard", isOn: keyboardEnabled)
                .accessibilityIdentifier("selection.keyboard")
            Stepper(
                value: debounce,
                in: 100...2_000,
                step: 50
            ) {
                LabeledContent(
                    "selection.debounce",
                    value: "\(viewModel.snapshot.selectionDebounceMilliseconds)"
                )
            }
            .accessibilityValue("\(viewModel.snapshot.selectionDebounceMilliseconds)")
            .accessibilityIdentifier("selection.debounce")
            Stepper(
                value: limit,
                in: 1...20_000,
                step: 100
            ) {
                LabeledContent(
                    "selection.limit",
                    value: "\(viewModel.snapshot.selectionCharacterLimit)"
                )
            }
            .accessibilityValue("\(viewModel.snapshot.selectionCharacterLimit)")
            .accessibilityIdentifier("selection.limit")

            Section("selection.clipboardFallback") {
                Text("selection.clipboardFallback.disclosure")
                Toggle("selection.clipboardFallback.enable", isOn: clipboardFallback)
                    .accessibilityHint("selection.clipboardFallback.enable.hint")
            }
            .accessibilityIdentifier("selection.clipboardFallback")
        }
        .formStyle(.grouped)
    }

    private var mouseEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.mouseSelectionEnabled },
            set: { value in
                viewModel.performOwned { await $0.setMouseSelectionEnabled(value) }
            }
        )
    }

    private var keyboardEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.keyboardSelectionEnabled },
            set: { value in
                viewModel.performOwned { await $0.setKeyboardSelectionEnabled(value) }
            }
        )
    }

    private var debounce: Binding<Int> {
        Binding(
            get: { viewModel.snapshot.selectionDebounceMilliseconds },
            set: { value in
                viewModel.performOwned {
                    await $0.setSelectionDebounceMilliseconds(value)
                }
            }
        )
    }

    private var limit: Binding<Int> {
        Binding(
            get: { viewModel.snapshot.selectionCharacterLimit },
            set: { value in
                viewModel.performOwned { await $0.setSelectionCharacterLimit(value) }
            }
        )
    }

    private var clipboardFallback: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.clipboardFallbackEnabled },
            set: { value in
                viewModel.performOwned {
                    await $0.setClipboardFallbackEnabled(
                        value,
                        disclosureVisible: true
                    )
                }
            }
        )
    }
}
