import SwiftUI

struct ContentView: View {
    @ObservedObject var store: RigStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            if let snapshot = store.snapshot {
                switch store.sidebarSelection {
                case .runtime:
                    AgentRuntimeView(store: store, snapshot: snapshot)
                case .localModels:
                    if store.leanMode {
                        AgentRuntimeView(store: store, snapshot: snapshot)
                    } else {
                        LocalModelView(store: store, snapshot: snapshot)
                    }
                case .rigs:
                    RigOverviewView(store: store, snapshot: snapshot)
                case .devServers:
                    DevServersView(store: store, snapshot: snapshot)
                case .mcps:
                    MCPUsageView(store: store, snapshot: snapshot)
                case .rig:
                    if let rig = store.selectedRig {
                        RigDetailView(store: store, snapshot: snapshot, rig: rig)
                    } else {
                        RigOverviewView(store: store, snapshot: snapshot)
                    }
                }
            } else if store.isRefreshing {
                ProgressView("Reading local rigs…")
            } else {
                ContentUnavailableView {
                    Label("Choose your workspace", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Select the folder containing scripts/rig2.sh or scripts/qa-rig.sh. Local Rig stores the choice for this Mac.")
                } actions: {
                    Button("Choose Workspace…") {
                        store.chooseWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .help("Refresh (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings (⌘,)")
            }
        }
        .alert("Rig needs attention", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .sheet(item: $store.handoffResult) { result in
            AgentHandoffSheet(store: store, result: result)
        }
        .task {
            store.startMonitoring()
        }
    }
}

private struct AgentHandoffSheet: View {
    let store: RigStore
    let result: AgentHandoffResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)

            Text(result.title)
                .font(.title2.weight(.semibold))
            Text(result.summary)
                .foregroundStyle(.secondary)

            Text(result.url.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Reveal in Finder") { store.reveal(result.url.path) }
                Button("Copy prompt again") { PasteboardService.copy(result.prompt) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

extension AgentHandoffResult: Identifiable {
    var id: String { url.path }
}
