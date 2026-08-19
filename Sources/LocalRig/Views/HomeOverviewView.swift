import SwiftUI

struct HomeOverviewView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @State private var terminationTarget: MCPUsageSnapshot?
    @State private var showCreateConfirmation = false

    private var sharedRigs: [RigSnapshot] { store.visibleRigs.filter { $0.mode == .shared } }
    private var isolatedRigs: [RigSnapshot] { store.visibleRigs.filter { $0.mode == .isolated } }
    private var devServers: [DevServerSnapshot] { snapshot.agentRuntime.devServers }
    private var mcpUsage: [MCPUsageSnapshot] { snapshot.agentRuntime.mcpUsageByType }
    private var totalMCPBytes: UInt64 { mcpUsage.reduce(0) { $0 + $1.residentBytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Home")
                            .font(.largeTitle.weight(.bold))
                        Text("Overview of your local dev rigs, shared emulators, and MCP processes.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Metric Summary Strip
                summaryStrip

                // Rigs & Dev Servers Section
                rigsSection

                // MCP Memory Section
                mcpSection
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("Home")
        .confirmationDialog(
            "End all \(terminationTarget?.name ?? "MCP") instances?",
            isPresented: Binding(
                get: { terminationTarget != nil },
                set: { if !$0 { terminationTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = terminationTarget {
                Button("End all instances", role: .destructive) {
                    terminationTarget = nil
                    Task { await store.terminateMCPGroup(target) }
                }
            }
            Button("Cancel", role: .cancel) { terminationTarget = nil }
        } message: {
            Text("Local Rig will gracefully terminate all instances of this MCP type. Survivors are never force-killed.")
        }
        .confirmationDialog(
            "Create the next available rig?",
            isPresented: $showCreateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Create and claim rig") {
                Task { await store.createNewRig() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates and claims the next free controller slot.")
        }
    }

    // MARK: - Metric Summary Strip

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            let memory = snapshot.systemMemory
            metricCard(
                title: "Memory Pressure",
                value: memory.pressureStatus,
                detail: "\(RigFormatters.memory(memory.physicalOccupiedBytes)) / \(RigFormatters.memory(memory.totalBytes))",
                systemImage: "memorychip",
                tint: memory.pressureStatus == "Normal" ? .green : .orange
            )

            metricCard(
                title: "Active Rigs",
                value: "\(store.runningRigCount) live",
                detail: "\(store.visibleRigs.count) configured",
                systemImage: "bolt.horizontal.circle",
                tint: store.runningRigCount > 0 ? .green : .secondary
            )

            metricCard(
                title: "Dev Servers",
                value: "\(devServers.count) running",
                detail: devServers.isEmpty ? "None active" : "Ports: " + devServers.map { ":\($0.port)" }.joined(separator: ", "),
                systemImage: "network",
                tint: !devServers.isEmpty ? .green : .secondary
            )

            metricCard(
                title: "MCP Fleet",
                value: RigFormatters.memory(totalMCPBytes),
                detail: "\(mcpUsage.count) types · \(mcpUsage.reduce(0) { $0 + $1.instanceCount }) procs",
                systemImage: "server.rack",
                tint: totalMCPBytes > 2_000_000_000 ? .orange : .secondary
            )
        }
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Rigs Section

    private var rigsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dev Rigs & Frontend Servers")
                        .font(.title2.weight(.semibold))
                    Text("Local web frontends bound to repo worktrees")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Create New Rig…", systemImage: "plus") {
                    showCreateConfirmation = true
                }
                .disabled(store.visibleRigs.count >= 5)
                .buttonStyle(.bordered)
            }

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(store.visibleRigs.enumerated()), id: \.element.id) { index, rig in
                        rigRow(rig)
                        if index < store.visibleRigs.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func rigRow(_ rig: RigSnapshot) -> some View {
        let ownsRig = rig.holder == store.claimName
        return HStack(spacing: 12) {
            Circle()
                .fill(rig.devIsRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rig.displayName)
                        .font(.headline)
                    if let holder = rig.holder {
                        Text("(\(holder))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("· \(rig.mode.title.lowercased()) emulator")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(":\(rig.devPort) · \(rig.repository.displayRevision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if rig.emulatorIsRunning {
                Label("Emulator live", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(RigFormatters.memory(rig.devResidentBytes + rig.emulatorResidentBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            HStack(spacing: 6) {
                if rig.devIsRunning {
                    Button("Open") {
                        store.open(URL(string: "http://127.0.0.1:\(rig.devPort)")!)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if ownsRig {
                        Button("Stop", systemImage: "stop.fill") {
                            Task { await store.run(.stopDev, on: rig.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if ownsRig {
                    Button("Start Shared", systemImage: "play.fill") {
                        Task { await store.run(.startShared, on: rig.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if rig.holder == nil {
                    Button("Claim") {
                        Task { await store.run(.claim(store.claimName), on: rig.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Details") {
                    store.sidebarSelection = .rig(rig.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - MCP Section

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Memory Footprint")
                        .font(.title2.weight(.semibold))
                    Text("Model Context Protocol tools active across sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage MCPs") {
                    store.sidebarSelection = .mcps
                }
                .buttonStyle(.bordered)
            }

            if mcpUsage.isEmpty {
                GroupBox {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        Text("No MCP processes currently running.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(mcpUsage.prefix(5).enumerated()), id: \.element.id) { index, item in
                            mcpRow(item)
                            if index < min(mcpUsage.count, 5) - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func mcpRow(_ item: MCPUsageSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .browser ? "globe" : "server.rack")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                Text("\(item.instanceCount) instance\(item.instanceCount == 1 ? "" : "s") · \(item.processCount) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(RigFormatters.memory(item.residentBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(item.residentBytes > 1_000_000_000 ? .orange : .primary)
                .frame(width: 90, alignment: .trailing)

            Button("End All") {
                terminationTarget = item
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.terminatingMCPTypeIDs.contains(item.id))
        }
        .padding(.vertical, 8)
    }
}
