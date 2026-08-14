import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: RigStore
    @AppStorage(PreferenceKeys.workspaceRoot) private var workspaceRoot = ""
    @AppStorage(PreferenceKeys.rig2ControlsEnabled) private var rig2ControlsEnabled = false
    @AppStorage(PreferenceKeys.claimName) private var claimName = RigCommandService.normalizedSessionName()

    private var workspaceIsValid: Bool {
        guard let root = workspaceRoot.nilIfBlank else { return true }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("scripts/qa-rig.sh").path)
            || FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("scripts/rig2.sh").path)
    }

    var body: some View {
        TabView {
            Form {
                Section("Workspace") {
                    HStack {
                        TextField("Auto-detect", text: $workspaceRoot)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            if let url = PanelService.chooseWorkspace() {
                                workspaceRoot = url.path
                                store.settingsDidChange()
                            }
                        }
                    }
                    if !workspaceIsValid {
                        Label("This folder does not contain a Rig controller script.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Leave blank to auto-detect from the app bundle, environment, or a supported workspace layout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Claims") {
                    TextField("Session name", text: $claimName)
                    if !RigCommandService.isValidClaimName(claimName) {
                        Text("Use 1–48 letters, numbers, dots, underscores, or dashes.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Machine profile") {
                    Toggle("Lean mode", isOn: $store.leanMode)
                    Text("Recommended for Macs with 24 GB or less. Hides local-model controls and polls less often while keeping rigs, dev servers, agent sessions, MCP memory, logs, and safe cleanup available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Multi-rig controller") {
                    if store.rig2IsVerified {
                        Label("Rig 2 verified — controls enabled", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Toggle("Enable unverified Rig 2 controls", isOn: $rig2ControlsEnabled)
                            .onChange(of: rig2ControlsEnabled) { _, _ in
                                store.settingsDidChange()
                            }
                    }
                    Text("Rig 2 supports five parallel rigs, shared or isolated emulators, and offset ports. A verified workspace enables it automatically; the override is only for deliberate bring-up before verification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(
                        "Reset, seed-save, repoint, and arbitrary commands are intentionally not exposed.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                }
            }
            .padding(20)
            .tabItem { Label("Safety", systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 390)
        .onChange(of: workspaceRoot) { _, _ in store.settingsDidChange() }
        .onChange(of: claimName) { _, _ in store.settingsDidChange() }
    }
}
