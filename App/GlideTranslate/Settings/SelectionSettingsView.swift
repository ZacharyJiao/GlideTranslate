import SharedSupport
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
                GlideStatusSurface(
                    message: LocalizedStringKey(
                        "selection.accessibility.status.\(viewModel.accessibilityStatus.rawValue)"
                    ),
                    nextAction: nil,
                    systemImage: accessibilityStatusSymbol
                )
                HStack(spacing: 8) { accessibilityButtons }
            }
            .accessibilityIdentifier("selection.accessibility")

            Section("selection.applications") {
                if viewModel.snapshot.generalAutomaticApplications.isEmpty {
                    Text("selection.applications.none")
                }
                if !sortedApplications.isEmpty {
                    SettingsApplicationGrid(applications: sortedApplications) { application in
                        Button {
                            viewModel.performOwned {
                                await $0.removeGeneralApplication(application)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("selection.applications.remove")
                        .accessibilityHint("selection.applications.remove.hint")
                        .help("selection.applications.remove")
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

            Section {
                HStack(spacing: 20) {
                    Toggle("selection.mouse", isOn: mouseEnabled)
                        .accessibilityIdentifier("selection.mouse")
                    Toggle("selection.keyboard", isOn: keyboardEnabled)
                        .accessibilityIdentifier("selection.keyboard")
                }
                HStack(spacing: 20) {
                    compactStepper(
                        value: viewModel.snapshot.selectionDebounceMilliseconds,
                        binding: debounce,
                        range: 100...2_000,
                        step: 50
                    ) { Text("selection.debounce") }
                    .accessibilityValue("\(viewModel.snapshot.selectionDebounceMilliseconds)")
                    .accessibilityIdentifier("selection.debounce")
                    compactStepper(
                        value: viewModel.snapshot.selectionCharacterLimit,
                        binding: limit,
                        range: 1...20_000,
                        step: 100
                    ) { Text("selection.limit") }
                    .accessibilityValue("\(viewModel.snapshot.selectionCharacterLimit)")
                    .accessibilityIdentifier("selection.limit")
                }
            }

            Section("selection.clipboardFallback") {
                Text("selection.clipboardFallback.disclosure")
                Toggle("selection.clipboardFallback.enable", isOn: clipboardFallback)
                    .accessibilityHint("selection.clipboardFallback.enable.hint")
            }
            .accessibilityIdentifier("selection.clipboardFallback")
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accessibilityButtons: some View {
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

    private var sortedApplications: [ApplicationIdentity] {
        viewModel.snapshot.generalAutomaticApplications.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func compactStepper<Label: View>(
        value: Int,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        @ViewBuilder label: () -> Label
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(verbatim: "\(value)")
                    .monospacedDigit()
                Spacer(minLength: 4)
                Stepper("", value: binding, in: range, step: step)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mouseEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.mouseSelectionEnabled },
            set: { value in
                viewModel.performOwned { await $0.setMouseSelectionEnabled(value) }
            }
        )
    }

    private var accessibilityStatusSymbol: String {
        switch viewModel.accessibilityStatus {
        case .granted: "checkmark.circle"
        case .denied: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
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
