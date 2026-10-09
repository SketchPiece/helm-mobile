import SwiftUI

/// Model, reasoning options, access, plan mode and auto-settle for a thread. Changes apply right away.
struct ThreadSettingsSheet: View {
    let environment: EnvironmentSession
    let session: ThreadSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var thread: ThreadSummary? { environment.thread(session.threadId) ?? session.projection?.thread }

    var body: some View {
        NavigationStack {
            Form {
                if let config = environment.config, let thread {
                    ModelSettingsSections(
                        config: config,
                        selection: thread.modelSelection,
                        runtimeMode: thread.runtimeMode,
                        interactionMode: thread.interactionMode,
                        onSelection: { selection in apply { try await session.setModel(selection) } },
                        onRuntimeMode: { mode in apply { try await session.setRuntimeMode(mode) } },
                        onInteractionMode: { mode in apply { try await session.setInteractionMode(mode) } }
                    )
                    if config.capability("threadAutoSettleOptOut") == true {
                        autoSettleSection(thread)
                    }
                } else {
                    ProgressView()
                }
                if let error {
                    Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Thread settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func autoSettleSection(_ thread: ThreadSummary) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { thread.autoSettleDisabledAt == nil },
                set: { enabled in
                    let ref = ThreadRef(environmentId: environment.id, threadId: session.threadId)
                    apply { try await model.perform(.autoSettle(enabled), on: ref) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-settle").font(Typography.body)
                    Text("Settles by itself once its pull request closes or after a few quiet days.")
                        .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
            }
            .tint(Palette.accent)
        }
    }

    private func apply(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                error = nil
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Shared by thread settings and the new-thread screen.
struct ModelSettingsSections: View {
    let config: ServerConfig
    let selection: ModelSelection?
    let runtimeMode: String
    let interactionMode: String
    let onSelection: (ModelSelection) -> Void
    let onRuntimeMode: (String) -> Void
    let onInteractionMode: (String) -> Void

    @State private var showLegacy = false

    var body: some View {
        Section {
            ForEach(config.usableProviders) { provider in
                let models = provider.models.filter { showLegacy || !$0.isLegacy || $0.slug == selection?.model }
                if !models.isEmpty {
                    Menu {
                        ForEach(models) { model in
                            Button {
                                onSelection(ModelSelection(instanceId: provider.instanceId, model: model.slug))
                            } label: {
                                if selection?.instanceId == provider.instanceId && selection?.model == model.slug {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            ProviderIcon(driver: provider.driver, iconUrl: provider.iconUrl, size: 18)
                                .frame(width: 22)
                            Text(provider.displayName).foregroundStyle(Palette.text)
                            Spacer()
                            if selection?.instanceId == provider.instanceId {
                                Text(config.modelLabel(for: selection))
                                    .foregroundStyle(Palette.accentText)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.placeholder)
                        }
                        .font(Typography.body)
                    }
                }
            }
            Toggle("Show older models", isOn: $showLegacy)
                .font(Typography.subheadline)
                .tint(Palette.accent)
        } header: {
            Text("Model").sectionLabelStyle()
        }

        if let selection, let model = config.model(for: selection), !model.options.isEmpty {
            Section {
                ForEach(model.options) { descriptor in
                    optionRow(descriptor, selection: selection)
                }
            } header: {
                Text("Options").sectionLabelStyle()
            }
        }

        Section {
            let supported = selection.flatMap { config.provider($0.instanceId)?.supportedRuntimeModes } ?? RuntimeMode.allCases.map(\.rawValue)
            ForEach(RuntimeMode.allCases.filter { supported.contains($0.rawValue) }) { mode in
                Button {
                    onRuntimeMode(mode.rawValue)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbol)
                            .frame(width: 22)
                            .foregroundStyle(Palette.textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).font(Typography.body).foregroundStyle(Palette.text)
                            Text(mode.detail).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                        }
                        Spacer()
                        if runtimeMode == mode.rawValue {
                            Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                        }
                    }
                }
            }
        } header: {
            Text("Access").sectionLabelStyle()
        }

        if selection.flatMap({ config.provider($0.instanceId)?.showInteractionModeToggle }) ?? false {
            Section {
                Toggle(isOn: Binding(get: { interactionMode == "plan" }, set: { onInteractionMode($0 ? "plan" : "default") })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan first").font(Typography.body)
                        Text("The agent proposes a plan and waits before changing anything.")
                            .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    }
                }
                .tint(Palette.accent)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ descriptor: ProviderOptionDescriptor, selection: ModelSelection) -> some View {
        let current = selection.options[descriptor.id] ?? descriptor.defaultValue
        if descriptor.type == "boolean" {
            Toggle(descriptor.label, isOn: Binding(
                get: { current?.bool ?? false },
                set: { value in
                    var next = selection
                    next.options[descriptor.id] = .bool(value)
                    onSelection(next)
                }
            ))
            .font(Typography.body)
            .tint(Palette.accent)
        } else {
            Picker(descriptor.label, selection: Binding(
                get: { current?.string ?? "" },
                set: { value in
                    var next = selection
                    next.options[descriptor.id] = .string(value)
                    onSelection(next)
                }
            )) {
                ForEach(descriptor.choices) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
            .font(Typography.body)
        }
    }
}

/// Files changed by a turn, fetched as a unified diff.
struct ChangesSheet: View {
    let session: ThreadSession
    let checkpoint: Checkpoint
    @Environment(\.dismiss) private var dismiss
    @State private var files: [DiffFile]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let files {
                    DiffFileList(files: files)
                } else if let error {
                    ContentUnavailableView("Couldn't load the changes", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .background(Palette.canvas)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task {
            do {
                let diff = try await session.turnDiff(checkpoint: checkpoint)
                files = await Task.detached { UnifiedDiff.parse(diff) }.value
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
