import PrivacyStorage
import SharedSupport
import SwiftUI

struct ModelsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selectedID: ProviderConfigurationID?
    @State private var protocolKind = ProviderProtocolKind.ollamaNative
    @State private var endpoint = "http://127.0.0.1:11434"
    @State private var model = ""
    @State private var credentialDisposition = SettingsCredentialDisposition.preserve

    var body: some View {
        Form {
            Section("models.providers") {
                ForEach(viewModel.providers) { descriptor in
                    HStack {
                        Button {
                            selectedID = descriptor.id
                            viewModel.performOwned {
                                await $0.selectProvider(descriptor.id)
                            }
                        } label: {
                            LabeledContent {
                                Text(LocalizedStringKey(descriptor.privacyClass.localizationKey))
                            } label: {
                                Text(LocalizedStringKey(descriptor.protocolKind.localizationKey))
                            }
                        }
                        if Self.canPrepareConfirmation(for: descriptor) {
                            Button("models.prepareConfirmation") {
                                selectedID = descriptor.id
                                viewModel.performOwned {
                                    await $0.prepareConfirmation(for: descriptor)
                                }
                            }
                        }
                    }
                }
                Button("models.reload") {
                    viewModel.performOwned { await $0.reloadProviders() }
                }
            }

            Picker("models.protocol", selection: $protocolKind) {
                Text("models.ollama").tag(ProviderProtocolKind.ollamaNative)
                Text("models.openAICompatible").tag(ProviderProtocolKind.openAICompatible)
            }
            .accessibilityIdentifier(
                protocolKind == .ollamaNative ? "models.ollama" : "models.openAICompatible"
            )
            TextField("models.endpoint", text: $endpoint)
            TextField("models.model", text: $model)
                .accessibilityIdentifier("models.model")
            SecureField(
                "models.credential",
                text: Binding(get: { "" }, set: { viewModel.setCredentialInput($0) })
            )
            Picker("models.credentialDisposition", selection: $credentialDisposition) {
                ForEach(SettingsCredentialDisposition.allCases) { disposition in
                    Text(LocalizedStringKey("models.credential.\(disposition.rawValue)"))
                        .tag(disposition)
                }
            }
            Button("models.save") { save() }

            if let selectedID {
                Button("models.discover") {
                    viewModel.performOwned { await $0.discoverModels(for: selectedID) }
                }
                ForEach(viewModel.discoveredModels, id: \.self) { discoveredModel in
                    Button(discoveredModel) { model = discoveredModel }
                }
                Button("models.connectionTest") {
                    viewModel.performOwned { await $0.testConnection(for: selectedID) }
                }
                .accessibilityIdentifier("models.connectionTest")
                Button("models.delete") {
                    viewModel.performOwned { await $0.deleteProvider(selectedID) }
                }
                .accessibilityHint("models.delete.hint")
                Button("models.automaticApplications.load") {
                    viewModel.performOwned {
                        await $0.loadAutomaticApplications(for: selectedID)
                    }
                }
                if viewModel.automaticApplicationsProviderID == selectedID {
                    ForEach(
                        viewModel.snapshot.generalAutomaticApplications.sorted {
                            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                        },
                        id: \.bundleIdentifier
                    ) { application in
                        Toggle(
                            application.displayName,
                            isOn: automaticApplication(application, id: selectedID)
                        )
                    }
                }
            }

            timeoutControls
                .accessibilityIdentifier("models.timeouts")

            if let preview = viewModel.confirmationPreview,
               preview.configurationID == selectedID {
                Text("models.confirmDestination.warning")
                Text(LocalizedStringKey(preview.protocolKind.localizationKey))
                Text(LocalizedStringKey(preview.privacyClass.localizationKey))
                Button("models.confirmDestination") {
                    viewModel.performOwned { await $0.confirmDestination() }
                }
                .accessibilityHint("models.confirmDestination.hint")
            }
            Color.clear.frame(height: 0)
                .accessibilityIdentifier("models.confirmDestination")
            Color.clear.frame(height: 0)
                .accessibilityIdentifier("models.automaticApplications")
        }
        .formStyle(.grouped)
        .onChange(of: viewModel.selectedProvider) { _, details in
            guard let details else {
                selectedID = nil
                model = ""
                return
            }
            selectedID = details.id
            protocolKind = details.protocolKind
            endpoint = details.endpoint.absoluteString
            model = details.model
            credentialDisposition = .preserve
        }
    }

    static func canPrepareConfirmation(
        for descriptor: SettingsProviderDescriptor
    ) -> Bool {
        descriptor.privacyClass != .localOnDevice
    }

    private var timeoutControls: some View {
        VStack(alignment: .leading) {
            Text("models.timeouts")
            Stepper(
                value: timeoutBinding(\.connectionTimeoutSeconds),
                in: 1...60
            ) {
                LabeledContent(
                    "models.timeout.connection",
                    value: "\(viewModel.snapshot.connectionTimeoutSeconds)"
                )
            }
            Stepper(
                value: timeoutBinding(\.firstTokenTimeoutSeconds),
                in: 5...600,
                step: 5
            ) {
                LabeledContent(
                    "models.timeout.firstToken",
                    value: "\(viewModel.snapshot.firstTokenTimeoutSeconds)"
                )
            }
            Stepper(
                value: timeoutBinding(\.streamIdleTimeoutSeconds),
                in: 5...120,
                step: 5
            ) {
                LabeledContent(
                    "models.timeout.streamIdle",
                    value: "\(viewModel.snapshot.streamIdleTimeoutSeconds)"
                )
            }
        }
    }

    private func timeoutBinding(_ keyPath: KeyPath<PreferencesSnapshot, Int>) -> Binding<Int> {
        Binding(
            get: { viewModel.snapshot[keyPath: keyPath] },
            set: { value in
                let snapshot = viewModel.snapshot
                let connection = keyPath == \.connectionTimeoutSeconds
                    ? value : snapshot.connectionTimeoutSeconds
                let firstToken = keyPath == \.firstTokenTimeoutSeconds
                    ? value : snapshot.firstTokenTimeoutSeconds
                let streamIdle = keyPath == \.streamIdleTimeoutSeconds
                    ? value : snapshot.streamIdleTimeoutSeconds
                viewModel.performOwned {
                    await $0.setTimeouts(
                        connection: connection,
                        firstToken: firstToken,
                        streamIdle: streamIdle
                    )
                }
            }
        )
    }

    private func automaticApplication(
        _ application: ApplicationIdentity,
        id: ProviderConfigurationID
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.automaticApplications.contains(application) },
            set: { enabled in
                var applications = viewModel.automaticApplications
                if enabled { applications.insert(application) }
                else { applications.remove(application) }
                viewModel.performOwned {
                    await $0.setAutomaticApplications(applications, for: id)
                }
            }
        )
    }

    private func save() {
        guard let url = URL(string: endpoint) else { return }
        let draft = SettingsProviderDraft(
            protocolKind: protocolKind,
            endpoint: url,
            model: model
        )
        viewModel.performOwned {
            await $0.saveProvider(
                id: selectedID,
                draft: draft,
                credentialDisposition: credentialDisposition
            )
        }
    }
}
