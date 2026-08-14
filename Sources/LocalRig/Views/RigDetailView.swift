import SwiftUI

struct RigDetailView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    let rig: RigSnapshot

    @State private var selectedLog: LogSelection = .dev
    @State private var confirmation: ConfirmationAction?
    @SceneStorage("terminalExpanded") private var terminalExpanded = false

    private var ownsRig: Bool { rig.holder == store.claimName }
    private var canRelease: Bool {
        ownsRig && !rig.devIsRunning && !(rig.mode == .isolated && rig.emulatorIsRunning)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear
                        .frame(height: 1)
                        .id("summary-top")

                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if !snapshot.rig2IsVerified {
                            UnverifiedRigBanner(enabled: store.rig2ControlsEnabled)
                        }

                        metrics
                        controls
                        repositoryCard
                        servicesCard
                    }
                    .padding(20)
                    .padding(.top, 28)
                }
                .task {
                    proxy.scrollTo("summary-top", anchor: .top)
                }
                .onChange(of: rig.id) { _, _ in
                    proxy.scrollTo("summary-top", anchor: .top)
                }
            }
            .frame(maxHeight: terminalExpanded ? 420 : .infinity)
            .layoutPriority(terminalExpanded ? 0 : 1)

            Divider()
            LogPanelView(
                selection: $selectedLog,
                isExpanded: $terminalExpanded,
                rig: rig,
                commandOutput: store.latestCommandOutput(for: rig.id),
                onHandoff: store.createAgentHandoff,
                onReveal: { store.reveal($0) }
            )
            .frame(
                minHeight: terminalExpanded ? 240 : 44,
                maxHeight: terminalExpanded ? .infinity : 44
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(rig.displayName)
        .confirmationDialog(
            confirmation?.title ?? "Confirm",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.buttonTitle, role: confirmation.role) {
                    Task { await store.run(confirmation.command, on: rig.id) }
                    self.confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(rig.devIsRunning ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(rig.devIsRunning ? "Dev server live" : "Dev server stopped")
                        .font(.title2.weight(.semibold))
                }
                Text("\(rig.profile.title) · \(rig.mode.title) emulator · \(rig.controller.rawValue)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if rig.devIsRunning {
                Button("Open localhost") {
                    store.open(URL(string: "http://localhost:\(rig.devPort)")!)
                }
            }
        }
    }

    private var metrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricCard(title: "Dev RAM", value: RigFormatters.memory(rig.devResidentBytes), image: "network")
                MetricCard(title: "Emulator RAM", value: RigFormatters.memory(rig.emulatorResidentBytes), image: "flame")
                MetricCard(title: "Memory pressure", value: snapshot.systemMemory.pressureStatus, image: "memorychip")
                MetricCard(title: "Holder", value: rig.holder ?? "Free", image: "person.crop.circle")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if rig.holder == nil {
                Button("Claim") {
                    Task { await store.run(.claim(store.claimName), on: rig.id) }
                }
            } else if ownsRig {
                Button("Release") {
                    Task { await store.run(.release, on: rig.id) }
                }
                .disabled(!canRelease)
            } else if let holder = rig.holder {
                Label("Held by \(holder)", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }

            if ownsRig && rig.devIsRunning {
                Button("Stop dev", systemImage: "stop.fill") {
                    Task { await store.run(.stopDev, on: rig.id) }
                }
            } else if ownsRig {
                Button("Start shared", systemImage: "play.fill") {
                    Task { await store.run(.startShared, on: rig.id) }
                }
                .disabled(rig.id > 1 && !store.rig2ControlsEnabled)
            }

            Menu("More") {
                Button("Run doctor") { Task { await store.run(.doctor, on: rig.id) } }
                if ownsRig {
                    Button("Rebuild functions") { Task { await store.run(.rebuild, on: rig.id) } }
                }
                Divider()
                if ownsRig {
                    Button("Start isolated…") { confirmation = .startIsolated }
                        .disabled(!store.rig2ControlsEnabled || rig.devIsRunning)
                }
                if ownsRig && rig.mode == .isolated && rig.emulatorIsRunning {
                    Button("Stop emulator…") { confirmation = .stopEmulator }
                } else if ownsRig && rig.mode == .isolated {
                    Button("Start emulator") { Task { await store.run(.startEmulator, on: rig.id) } }
                }
            }

            if store.isSelectedRigBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Send to agent", systemImage: "paperplane") {
                store.createAgentHandoff()
            }
        }
        .buttonStyle(.bordered)
    }

    private var repositoryCard: some View {
        GroupBox("Bound worktrees") {
            VStack(spacing: 12) {
                repositoryRow(title: "Dashboard", repository: rig.repository)
                Divider()
                repositoryRow(title: "Backend", repository: rig.backendRepository)
            }
            .padding(.vertical, 4)
        }
    }

    private func repositoryRow(title: String, repository: RepositoryIdentity) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(repository.displayRevision)
                    .font(.headline)
                if let summary = repository.summary {
                    Text("\(repository.commit ?? "") · \(summary)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(repository.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Reveal") { store.reveal(repository.path) }
                .disabled(!repository.exists)
        }
    }

    private var servicesCard: some View {
        GroupBox("Services · ports are truth") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(rig.services) { service in
                    GridRow {
                        Image(systemName: service.kind.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(service.kind.rawValue)
                        Text(":\(String(service.port))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(service.isListening ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(service.isListening ? "Listening" : "Down")
                            if service.isShared { Text("· shared from Rig 1") }
                        }
                        .foregroundStyle(service.isListening ? .primary : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private enum ConfirmationAction {
    case startIsolated
    case stopEmulator

    var title: String {
        switch self {
        case .startIsolated: "Start an isolated rig?"
        case .stopEmulator: "Stop this emulator?"
        }
    }
    var message: String {
        switch self {
        case .startIsolated: "This can use roughly 3.5 GB. The rig script owns the boot, port, memory, and isolation checks."
        case .stopEmulator: "This stops backend services and may export emulator state. Shared-infrastructure protections remain enforced by the rig script."
        }
    }
    var buttonTitle: String {
        switch self {
        case .startIsolated: "Start isolated"
        case .stopEmulator: "Stop emulator"
        }
    }
    var role: ButtonRole? { self == .stopEmulator ? .destructive : nil }
    var command: RigCommand { self == .stopEmulator ? .stopEmulator : .startIsolated }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let image: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: image)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct UnverifiedRigBanner: View {
    let enabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Rig 2 is still marked unverified")
                    .font(.headline)
                Text(enabled
                     ? "Controls were explicitly enabled in Settings. The seven-step verification checklist has not been recorded as complete."
                     : "Legacy QA Rig remains the default controller. Enable Rig 2 controls in Settings only when you intentionally want the draft multi-rig path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3)))
    }
}
