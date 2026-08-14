import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: RigStore

    var body: some View {
        List(selection: Binding(
            get: { store.sidebarSelection },
            set: { selection in
                guard selection != store.sidebarSelection else { return }
                Task { @MainActor in
                    await Task.yield()
                    store.sidebarSelection = selection
                }
            }
        )) {
            Section("Workspace") {
                SidebarDestinationRow(
                    title: "Rigs",
                    detail: "\(store.visibleRigs.count) configured · \(store.runningRigCount) live",
                    systemImage: "bolt.horizontal.circle"
                )
                .tag(SidebarSelection.rigs)

                let devServerCount = store.agentRuntime?.devServers.count ?? 0
                SidebarDestinationRow(
                    title: "Dev Servers",
                    detail: "\(devServerCount) running",
                    systemImage: "network"
                )
                .tag(SidebarSelection.devServers)

                let mcpTypes = store.agentRuntime?.mcpUsageByType ?? []
                SidebarDestinationRow(
                    title: "MCPs",
                    detail: "\(mcpTypes.count) types · \(mcpTypes.reduce(0) { $0 + $1.instanceCount }) instances",
                    systemImage: "server.rack"
                )
                .tag(SidebarSelection.mcps)
            }

            Section("Agents") {
                SidebarDestinationRow(
                    title: "Agent Runtimes",
                    detail: runtimeDetail,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .tag(SidebarSelection.runtime)

                if !store.leanMode, let localModel = store.snapshot?.localModel {
                    SidebarDestinationRow(
                        title: "Local Models",
                        detail: "\(localModel.selectedModel.title) · \(localModel.status.title.lowercased())",
                        systemImage: "cpu",
                        tint: localModel.status == .ready || localModel.status == .busy ? .green : .secondary
                    )
                    .tag(SidebarSelection.localModels)
                }
            }

            if let memory = store.snapshot?.systemMemory {
                Section("Machine") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Memory Pressure")
                            Text("\(memory.pressureStatus) · \(RigFormatters.memory(memory.physicalOccupiedBytes)) / \(RigFormatters.memory(memory.totalBytes)) occupied")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "memorychip")
                            .foregroundStyle(.secondary)
                    }
                    if store.leanMode {
                        Label("Lean mode · local models hidden", systemImage: "leaf")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Local Rig")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle()
                    .fill(store.runningRigCount > 0 ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                let serverCount = store.agentRuntime?.devServers.count ?? 0
                Text("\(serverCount) dev server\(serverCount == 1 ? "" : "s") running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let count = store.agentRuntime?.staleCandidateCount, count > 0 {
                    Label("\(count)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Possible stale agent process groups")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var runtimeDetail: String {
        guard let runtime = store.agentRuntime else { return "Reading processes…" }
        return "\(runtime.estimatedSessionCount) sessions · \(runtime.staleCandidateCount) review"
    }
}

private struct SidebarDestinationRow: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)
        }
    }
}
