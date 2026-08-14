import SwiftUI

struct DevServersView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @State private var terminationTarget: DevServerSnapshot?

    private var servers: [DevServerSnapshot] { snapshot.agentRuntime.devServers }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Dev Servers")
                            .font(.largeTitle.weight(.bold))
                        Text("Every detected local development listener, including servers started outside Local Rig.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(servers.count) running")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if servers.isEmpty {
                    ContentUnavailableView(
                        "No dev servers detected",
                        systemImage: "network.slash",
                        description: Text("Local Rig discovers common Node and frontend development listeners from live ports.")
                    )
                    .frame(minHeight: 300)
                } else {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                                devServerRow(server)
                                if index < servers.count - 1 { Divider() }
                            }
                        }
                    }
                }

                Text("Stop always asks first. Local Rig re-scans the port and requires the same root PID and command before sending SIGTERM. Emulator and local-model listeners are protected, and survivors are never force-killed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("Dev Servers")
        .confirmationDialog(
            "Stop \(terminationTarget.map(projectName) ?? "dev server")?",
            isPresented: Binding(
                get: { terminationTarget != nil },
                set: { if !$0 { terminationTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = terminationTarget {
                Button("Stop dev server", role: .destructive) {
                    terminationTarget = nil
                    Task { await store.terminateDevServer(target) }
                }
            }
            Button("Cancel", role: .cancel) { terminationTarget = nil }
        } message: {
            Text(terminationMessage)
        }
    }

    private func devServerRow(_ server: DevServerSnapshot) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(.green)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName(server))
                    .font(.headline)
                Text(server.ownerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = server.repositoryPath {
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            metric("Port", ":\(server.port)")
            metric("Age", RigFormatters.duration(server.ageSeconds))
            metric("RAM", RigFormatters.memory(server.residentBytes))
            metric("Processes", "\(server.processes.count)")
            Button {
                store.open(URL(string: "http://127.0.0.1:\(server.port)")!)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open localhost:\(server.port)")
            Button {
                terminationTarget = server
            } label: {
                if store.terminatingDevServerIDs.contains(server.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "stop.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.terminatingDevServerIDs.contains(server.id))
            .accessibilityLabel("Stop \(projectName(server))")
            .help("Re-check and gracefully stop this dev server")
        }
        .padding(.vertical, 11)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(minWidth: 58, alignment: .trailing)
    }

    private func projectName(_ server: DevServerSnapshot) -> String {
        server.repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
    }

    private var terminationMessage: String {
        guard let server = terminationTarget else { return "" }
        if let rig = store.controlledRig(for: server), rig.holder == store.claimName {
            return "This server matches your claimed Rig \(rig.id), so Local Rig will stop it through the verified rig controller. The emulator stays running."
        }
        return "Local Rig will re-scan :\(server.port) and require the exact same root PID and command before gracefully stopping only that dev-server tree. Owner: \(server.ownerLabel). Any surviving processes will be reported and never force-killed."
    }
}
