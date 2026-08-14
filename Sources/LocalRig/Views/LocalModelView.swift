import SwiftUI

struct LocalModelView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @AppStorage(PreferenceKeys.localModelChoice) private var modelChoice = LocalModelChoice.qwen36_27B_Q4
    @AppStorage(PreferenceKeys.localModelProfile) private var profile = LocalModelProfile.standard
    @AppStorage(PreferenceKeys.localModelFeatureProfile) private var featureProfile = LocalModelFeatureProfile.accelerated
    @SceneStorage("localModel.logsExpanded") private var logsExpanded = true
    @State private var confirmation: LocalModelConfirmation?

    private var model: LocalModelSnapshot { snapshot.localModel }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if snapshot.systemMemory.pressureStatus != "Normal" {
                        pressureBanner
                    }
                    metrics
                    controls
                    configurationCard
                    modelRoadmapCard
                }
                .padding(24)
                .frame(maxWidth: 1_120, alignment: .leading)
            }
            .frame(maxHeight: logsExpanded ? 500 : .infinity)

            Divider()
            logs
                .frame(minHeight: logsExpanded ? 220 : 44, maxHeight: logsExpanded ? .infinity : 44)
        }
        .navigationTitle("Local Models")
        .confirmationDialog(
            confirmation?.title ?? "Confirm",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.buttonTitle) {
                    let action = confirmation
                    self.confirmation = nil
                    Task {
                        switch action {
                        case .download: await store.downloadLocalModel()
                        case .start: await store.startLocalModel()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: modelChoice) { _, choice in
            if !choice.supportedFeatureProfiles.contains(featureProfile) {
                featureProfile = .textOnly
            }
            store.localModelSettingsDidChange()
        }
        .onChange(of: profile) { _, _ in store.localModelSettingsDidChange() }
        .onChange(of: featureProfile) { _, _ in store.localModelSettingsDidChange() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text("Local AI · \(model.status.title)")
                        .font(.largeTitle.weight(.semibold))
                }
                Text("A machine-level llama.cpp service managed separately from dev rigs and agent sessions.")
                    .foregroundStyle(.secondary)
                Text(model.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.status == .ready || model.status == .busy || model.status == .sleeping {
                Button("Open API") {
                    store.open(URL(string: model.endpoint.replacingOccurrences(of: "/v1", with: ""))!)
                }
            }
        }
    }

    private var pressureBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "memorychip.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory pressure is \(snapshot.systemMemory.pressureStatus.lowercased())")
                    .font(.headline)
                Text("\(RigFormatters.memory(snapshot.systemMemory.physicalOccupiedBytes)) of \(RigFormatters.memory(snapshot.systemMemory.totalBytes)) is occupied and \(RigFormatters.memory(snapshot.systemMemory.compressedBytes)) is compressed. Downloading is safe; loading the model now may slow active agents and rigs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3)))
    }

    private var metrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                LocalModelMetric(title: "Model RAM", value: RigFormatters.memory(model.residentBytes), detail: model.processPID.map { "PID \($0)" } ?? "not loaded", image: "memorychip")
                LocalModelMetric(
                    title: "Artifacts",
                    value: RigFormatters.memory(model.modelFileBytes),
                    detail: "\(model.downloadedArtifactCount) of \(model.requiredArtifactCount) ready",
                    image: "internaldrive"
                )
                LocalModelMetric(title: "Context", value: "\(model.profile.contextSize / 1_024)k", detail: model.profile.title, image: "text.line.last.and.arrowtriangle.forward")
            }
            GridRow {
                LocalModelMetric(title: "Requests", value: "\(model.requestsProcessing)", detail: "processing now", image: "arrow.left.arrow.right")
                LocalModelMetric(title: "Prompt speed", value: speed(model.promptTokensPerSecond), detail: "tokens / second", image: "gauge.with.dots.needle.33percent")
                LocalModelMetric(title: "Generation", value: speed(model.predictedTokensPerSecond), detail: "tokens / second", image: "text.badge.plus")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if !model.runtimeInstalled {
                Button("Install llama.cpp", systemImage: "shippingbox.and.arrow.backward") {
                    Task { await store.installLocalModelRuntime() }
                }
            } else if model.processPID != nil {
                Button("Stop model", systemImage: "stop.fill", role: .destructive) {
                    Task { await store.stopLocalModel() }
                }
            } else if !model.modelDownloaded && model.selectedModel.downloadURL != nil {
                Button("Download model", systemImage: "arrow.down.circle") {
                    confirmation = .download
                }
            } else if model.modelDownloaded {
                Button("Start model", systemImage: "play.fill") {
                    confirmation = .start
                }
                .buttonStyle(.borderedProminent)
            }

            if store.isLocalModelBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Copy agent config", systemImage: "doc.on.doc") {
                PasteboardService.copy(agentConfiguration)
            }
            Button("Reveal files", systemImage: "folder") {
                store.reveal(model.modelFilePath ?? model.logPath)
            }
        }
        .buttonStyle(.bordered)
        .disabled(store.isLocalModelBusy)
    }

    private var configurationCard: some View {
        GroupBox("Runtime configuration") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Model", selection: $modelChoice) {
                    ForEach(LocalModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .disabled(model.processPID != nil || store.isLocalModelBusy)

                Picker("Memory profile", selection: $profile) {
                    ForEach(LocalModelProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.processPID != nil || store.isLocalModelBusy)

                if modelChoice.isMuseGlimmer {
                    Picker("Components", selection: $featureProfile) {
                        ForEach(modelChoice.supportedFeatureProfiles) { feature in
                            Text(feature.title).tag(feature)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.processPID != nil || store.isLocalModelBusy)
                }

                Text(runtimeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
    }

    private var modelRoadmapCard: some View {
        GroupBox("Local model catalog") {
            VStack(spacing: 0) {
                ForEach(Array(LocalModelChoice.allCases.enumerated()), id: \.element.id) { index, choice in
                    let isAvailable = choice.downloadURL != nil
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isAvailable ? "checkmark.circle.fill" : "clock")
                            .foregroundStyle(isAvailable ? Color.green : Color.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title)
                                .font(.headline)
                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(isAvailable ? "Available" : "Unavailable")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isAvailable ? Color.green : Color.secondary)
                    }
                    .padding(.vertical, 10)
                    if index < LocalModelChoice.allCases.count - 1 { Divider() }
                }
            }
        }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            Button {
                logsExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: logsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Label("llama.cpp logs", systemImage: "terminal")
                    Spacer()
                    Text(model.logPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .frame(height: 43)
            }
            .buttonStyle(.plain)

            if logsExpanded {
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(model.redactedLogTail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .download:
            let bytes = modelChoice.requiredArtifacts(for: effectiveFeatureProfile)
                .reduce(UInt64(0)) { $0 + $1.expectedBytes }
            let verification = modelChoice.isMuseGlimmer ? " Meta artifacts are verified with SHA-256." : ""
            return "This downloads about \(RigFormatters.memory(bytes)) into Local Rig's Application Support folder.\(verification) It does not load the model into memory."
        case .start:
            return "This loads \(model.selectedModel.title) in \(model.featureProfile.title.lowercased()) mode with a \(model.profile.contextSize / 1_024)k context. Current memory pressure is \(snapshot.systemMemory.pressureStatus.lowercased()). Active rigs and agents are never stopped automatically."
        case nil:
            return ""
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .ready: .green
        case .busy: .blue
        case .sleeping, .stopped: .secondary
        case .downloading, .starting: .orange
        case .error: .red
        default: .secondary
        }
    }

    private var agentConfiguration: String {
        let modelID = model.selectedModel.isMuseGlimmer ? "muse-glimmer" : model.selectedModel.rawValue
        return """
        OPENAI_BASE_URL=\(model.endpoint)
        OPENAI_API_KEY=local
        OPENAI_MODEL=\(modelID)
        """
    }

    private var effectiveFeatureProfile: LocalModelFeatureProfile {
        modelChoice.supportedFeatureProfiles.contains(featureProfile) ? featureProfile : .textOnly
    }

    private var runtimeSummary: String {
        let components = modelChoice.isMuseGlimmer
            ? "\(effectiveFeatureProfile.title) components"
            : "Text"
        return "One request slot · \(components) · Metal offload · Q8 KV cache · automatic sleep after 10 idle minutes · loopback only on :\(model.port). Changes apply on the next start."
    }

    private func speed(_ value: Double?) -> String {
        value.map { String(format: "%.1f t/s", $0) } ?? "—"
    }
}

private enum LocalModelConfirmation {
    case download
    case start

    var title: String { self == .download ? "Download local model?" : "Load local model?" }
    var buttonTitle: String { self == .download ? "Download" : "Start model" }
}

private struct LocalModelMetric: View {
    let title: String
    let value: String
    let detail: String
    let image: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: image)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
