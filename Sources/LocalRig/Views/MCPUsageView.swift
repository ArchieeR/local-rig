import SwiftUI

struct MCPUsageView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @State private var terminationTarget: MCPUsageSnapshot?

    private var usage: [MCPUsageSnapshot] { snapshot.agentRuntime.mcpUsageByType }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MCPs")
                            .font(.largeTitle.weight(.bold))
                        Text("Usage grouped by MCP type and sorted by memory.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(RigFormatters.memory(usage.reduce(0) { $0 + $1.residentBytes }))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if usage.isEmpty {
                    ContentUnavailableView(
                        "No MCP processes detected",
                        systemImage: "server.rack",
                        description: Text("MCP types appear here when Codex or Claude starts them.")
                    )
                    .frame(minHeight: 300)
                } else {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(usage.enumerated()), id: \.element.id) { index, item in
                                usageRow(item)
                                if index < usage.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("MCPs")
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
            Text(terminationMessage)
        }
    }

    private func usageRow(_ item: MCPUsageSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind == .browser ? "globe" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text("\(item.instanceCount) instance\(item.instanceCount == 1 ? "" : "s") · \(item.sessionCount) session\(item.sessionCount == 1 ? "" : "s") · \(item.processCount) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.sessionTitles.isEmpty {
                    Text(item.sessionTitles.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(String(format: "%.1f%% CPU", item.cpuPercent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(RigFormatters.memory(item.residentBytes))
                .font(.headline.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
            Button {
                terminationTarget = item
            } label: {
                if store.terminatingMCPTypeIDs.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stop.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.terminatingMCPTypeIDs.contains(item.id))
            .accessibilityLabel("End all \(item.name) instances")
            .help("Re-check and gracefully stop every instance of this MCP type")
        }
        .padding(.vertical, 11)
    }

    private var terminationMessage: String {
        guard let item = terminationTarget else { return "" }
        let sessions = item.sessionTitles.isEmpty
            ? "No active session attribution is available."
            : "Affected sessions: \(item.sessionTitles.joined(separator: ", "))."
        let browserSafety = item.kind == .browser
            ? " Only isolated browser-MCP roots and their descendants are eligible; a personal browser root is never matched."
            : ""
        return "Local Rig will require the exact same MCP root PIDs and commands before sending SIGTERM. Sessions may respawn the tool on next use. Survivors are never force-killed. \(sessions)\(browserSafety)"
    }
}
