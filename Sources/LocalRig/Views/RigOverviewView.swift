import SwiftUI

struct RigOverviewView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @State private var showCreateConfirmation = false

    private var sharedRigs: [RigSnapshot] { store.visibleRigs.filter { $0.mode == .shared } }
    private var isolatedRigs: [RigSnapshot] { store.visibleRigs.filter { $0.mode == .isolated } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Rigs")
                            .font(.largeTitle.weight(.bold))
                        Text("All configured frontends and their emulator topology on one page.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Create New Rig…", systemImage: "plus") {
                        showCreateConfirmation = true
                    }
                    .disabled(store.visibleRigs.count >= 5)
                }

                if !sharedRigs.isEmpty {
                    rigSection("Shared emulator", detail: "Frontends use Rig 1's Firebase state", rigs: sharedRigs)
                }
                if !isolatedRigs.isEmpty {
                    rigSection("Own emulator", detail: "Independent Firebase ports and state", rigs: isolatedRigs)
                }
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("Rigs")
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
            Text("This creates and claims the next free controller slot. It does not start a frontend or emulator; choose shared or isolated after creation.")
        }
    }

    private func rigSection(_ title: String, detail: String, rigs: [RigSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rigs) { rig in
                RigOverviewCard(store: store, rig: rig)
            }
        }
    }
}

private struct RigOverviewCard: View {
    @ObservedObject var store: RigStore
    let rig: RigSnapshot

    private var ownsRig: Bool { rig.holder == store.claimName }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(rig.devIsRunning ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rig.displayName)
                            .font(.headline)
                        Text("\(rig.holder ?? "free") · \(rig.mode.title.lowercased()) emulator · :\(rig.devPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(RigFormatters.memory(rig.devResidentBytes + rig.emulatorResidentBytes))
                        .font(.headline.monospacedDigit())
                    if rig.devIsRunning {
                        Button("Open") {
                            store.open(URL(string: "http://127.0.0.1:\(rig.devPort)")!)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if rig.holder == nil {
                        Button("Claim") {
                            Task { await store.run(.claim(store.claimName), on: rig.id) }
                        }
                    } else if !ownsRig {
                        Label("Held by \(rig.holder ?? "another session")", systemImage: "lock.fill")
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

                        Button("Start isolated…") {
                            store.sidebarSelection = .rig(rig.id)
                        }
                        .disabled(!store.rig2ControlsEnabled)
                        .help("Open this rig's detailed controls before starting an isolated emulator")
                    }

                    Button("Doctor") {
                        Task { await store.run(.doctor, on: rig.id) }
                    }
                    Spacer()
                    Button("Details") {
                        store.sidebarSelection = .rig(rig.id)
                    }
                }
                .buttonStyle(.bordered)

                Divider()
                HStack(spacing: 16) {
                    Label(rig.repository.displayRevision, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(rig.emulatorIsRunning ? "Emulator live" : "Emulator stopped", systemImage: "flame")
                    Label(rig.profile.title, systemImage: "slider.horizontal.3")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
