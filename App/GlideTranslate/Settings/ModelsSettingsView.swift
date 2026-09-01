import PrivacyStorage
import SharedSupport
import SwiftUI

struct ModelsSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selectedID: ProviderConfigurationID?
    @State private var protocolKind = ProviderProtocolKind.openAICompatible
    @State private var endpoint = ""
    @State private var model = ""
    @State private var credentialDisposition = SettingsCredentialDisposition.replace
    @State private var isCreatingProvider = false

    var body: some View {
        HSplitView {
            providerList
            configurationForm
                .frame(minWidth: 280)
        }
        .task { await selectInitialProviderIfNeeded() }
        .onChange(of: viewModel.providers) { _, _ in
            Task { await selectInitialProviderIfNeeded() }
        }
        .onChange(of: viewModel.selectedProvider) { _, details in
            guard let details else { return }
            selectedID = details.id
            protocolKind = details.protocolKind
            endpoint = details.endpoint.absoluteString
            model = details.model
            credentialDisposition = details.hasCredential ? .preserve : .replace
        }
        .onChange(of: protocolKind) { _, kind in
            guard selectedID == nil else { return }
            endpoint = kind == .ollamaNative ? "http://127.0.0.1:11434" : ""
        }
    }

    private var configurationForm: some View {
        Form {
            connectionSection

            if selectedID != nil {
                modelSelectionSection
                providerActionsSection
            }

            Section("models.timeouts") {
                timeoutControls
                    .accessibilityIdentifier("models.timeouts")
            }

        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            List(viewModel.providers, selection: providerSelection) { descriptor in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProviderDefaultIndicator(
                            isDefault: descriptor.id == viewModel.snapshot.defaultProviderID
                        )
                        Text(LocalizedStringKey(descriptor.protocolKind.localizationKey))
                        if descriptor.id == viewModel.snapshot.defaultProviderID {
                            Text("models.active")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: descriptor.model.isEmpty ? "—" : descriptor.model)
                        .font(.caption)
                        .lineLimit(1)
                    Text(LocalizedStringKey(descriptor.readiness.localizationKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Optional(descriptor.id))
            }
            .accessibilityIdentifier("models.providers")

            HStack {
                Button {
                    beginNewProvider()
                } label: {
                    Label("models.new", systemImage: "plus")
                }
                Spacer()
                Button("models.reload") {
                    viewModel.performOwned { await $0.reloadProviders() }
                }
            }
            .padding(8)
        }
        .frame(
            minWidth: 150,
            idealWidth: 170,
            maxWidth: 190
        )
    }

    private var connectionSection: some View {
        Section("models.connection") {
            Picker("models.providerType", selection: $protocolKind) {
                Text("models.openAICompatible").tag(ProviderProtocolKind.openAICompatible)
                Text("models.ollama").tag(ProviderProtocolKind.ollamaNative)
            }
            .accessibilityIdentifier(
                protocolKind == .ollamaNative ? "models.ollama" : "models.openAICompatible"
            )

            TextField("models.endpoint", text: $endpoint)
                .onSubmit { connectAndLoadModels() }

            SecureField(
                "models.apiKey",
                text: Binding(
                    get: { viewModel.credentialDraft },
                    set: { value in
                        viewModel.setCredentialInput(value, for: selectedID)
                        if !value.isEmpty { credentialDisposition = .replace }
                    }
                )
            )
            .onSubmit { connectAndLoadModels() }

            if selectedDescriptor?.hasCredential == true,
               viewModel.credentialFieldIsEmpty {
                Label("models.apiKey.stored", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("models.connection.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                connectAndLoadModels()
            } label: {
                if viewModel.providerConnectionInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("models.connect", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(GlideVisualTokens.actionEmerald)
            .disabled(!canConnect)
            .accessibilityIdentifier("models.connect")
        }
    }

    private var modelSelectionSection: some View {
        Section("models.availableModels") {
            if availableModelOptions.isEmpty {
                Text("models.availableModels.empty")
                    .foregroundStyle(.secondary)
            } else {
                Picker("models.model", selection: $model) {
                    Text("models.model.choose").tag("")
                    ForEach(availableModelOptions, id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .accessibilityIdentifier("models.model")
            }

            HStack {
                Button {
                    connectAndLoadModels()
                } label: {
                    Label("models.refreshModels", systemImage: "arrow.clockwise")
                }
                .disabled(!canConnect)

                Spacer()

                Button("models.activateModel") {
                    guard let selectedID else { return }
                    viewModel.performOwned {
                        await $0.activateProviderModel(selectedID, model: model)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(GlideVisualTokens.actionEmerald)
                .disabled(
                    model.isEmpty
                        || viewModel.providerActivationInFlight
                        || !availableModelOptions.contains(model)
                )
                .accessibilityIdentifier("models.activateModel")
            }

            if let selectedID,
               viewModel.snapshot.defaultProviderID == selectedID {
                Label("models.active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(GlideVisualTokens.actionEmerald)
            }
        }
    }

    @ViewBuilder
    private var providerActionsSection: some View {
        if let selectedID {
            Section("models.actions") {
                Button("models.delete") {
                    self.selectedID = nil
                    model = ""
                    viewModel.performOwned { await $0.deleteProvider(selectedID) }
                }
                .accessibilityHint("models.delete.hint")
                .foregroundStyle(.red)

                Button("models.automaticApplications.load") {
                    viewModel.performOwned {
                        await $0.loadAutomaticApplications(for: selectedID)
                    }
                }
                if viewModel.automaticApplicationsProviderID == selectedID {
                    SettingsApplicationGrid(applications: sortedApplications) { application in
                        Toggle(
                            "",
                            isOn: automaticApplication(application, id: selectedID)
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
            }
            .accessibilityIdentifier("models.automaticApplications")
        }
    }

    private var providerSelection: Binding<ProviderConfigurationID?> {
        Binding(
            get: { selectedID },
            set: { id in
                selectedID = id
                guard let id else {
                    viewModel.beginNewProviderCredentialDraft()
                    return
                }
                isCreatingProvider = false
                viewModel.beginProviderCredentialDraft(for: id)
                viewModel.performOwned { await $0.selectProvider(id) }
            }
        )
    }

    private var selectedDescriptor: SettingsProviderDescriptor? {
        guard let selectedID else { return nil }
        return viewModel.providers.first { $0.id == selectedID }
    }

    private var availableModelOptions: [String] {
        var options = Set(viewModel.discoveredModels)
        if !model.isEmpty { options.insert(model) }
        return options.sorted()
    }

    private var canConnect: Bool {
        guard !viewModel.providerConnectionInFlight,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        if protocolKind == .ollamaNative { return true }
        return selectedDescriptor?.hasCredential == true
            || !viewModel.credentialFieldIsEmpty
    }

    private func beginNewProvider() {
        isCreatingProvider = true
        selectedID = nil
        viewModel.beginNewProviderCredentialDraft()
        protocolKind = .openAICompatible
        endpoint = ""
        model = ""
        credentialDisposition = .replace
    }

    private func selectInitialProviderIfNeeded() async {
        guard !isCreatingProvider, selectedID == nil else { return }
        let validDefault = viewModel.snapshot.defaultProviderID.flatMap { id in
            viewModel.providers.contains(where: { $0.id == id }) ? id : nil
        }
        guard let id = validDefault ?? viewModel.providers.first?.id else { return }
        selectedID = id
        viewModel.beginProviderCredentialDraft(for: id)
        await viewModel.performOwnedAndWait { await $0.selectProvider(id) }
    }

    private var sortedApplications: [ApplicationIdentity] {
        viewModel.snapshot.generalAutomaticApplications.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func connectAndLoadModels() {
        guard canConnect, let url = URL(string: endpoint) else { return }
        let disposition: SettingsCredentialDisposition
        if !viewModel.credentialFieldIsEmpty {
            disposition = .replace
        } else if selectedDescriptor?.hasCredential == true {
            disposition = .preserve
        } else {
            disposition = credentialDisposition
        }
        let draft = SettingsProviderDraft(
            protocolKind: protocolKind,
            endpoint: url,
            model: model
        )
        viewModel.performOwned {
            await $0.connectProvider(
                id: selectedID,
                draft: draft,
                credentialDisposition: disposition
            )
        }
    }

    private var timeoutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeoutRow(
                value: viewModel.snapshot.connectionTimeoutSeconds,
                binding: timeoutBinding(\.connectionTimeoutSeconds),
                range: 1...60
            ) { Text("models.timeout.connection") }
            timeoutRow(
                value: viewModel.snapshot.firstTokenTimeoutSeconds,
                binding: timeoutBinding(\.firstTokenTimeoutSeconds),
                range: 5...600,
                step: 5
            ) { Text("models.timeout.firstToken") }
            timeoutRow(
                value: viewModel.snapshot.streamIdleTimeoutSeconds,
                binding: timeoutBinding(\.streamIdleTimeoutSeconds),
                range: 5...120,
                step: 5
            ) { Text("models.timeout.streamIdle") }
        }
    }

    private func timeoutRow<Label: View>(
        value: Int,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 8) {
            label()
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "\(value)")
                .monospacedDigit()
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
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
}

struct ProviderDefaultIndicator: View {
    let isDefault: Bool

    var body: some View {
        Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
                isDefault ? GlideVisualTokens.actionEmerald : Color.secondary
            )
            .accessibilityHidden(true)
    }
}
