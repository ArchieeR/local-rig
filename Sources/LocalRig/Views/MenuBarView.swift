import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: RigStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let runtime = store.agentRuntime {
            Button {
                store.selectedRigID = 0
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Sessions · \(runtime.activeSessionCount) active / \(runtime.estimatedSessionCount) observed")
            }
            if runtime.staleCandidateCount > 0 {
                Button {
                    store.selectedRigID = 0
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Review \(runtime.staleCandidateCount) stale candidates")
                }
            }
            Divider()
        }

        if !store.leanMode, let localModel = store.snapshot?.localModel {
            Button {
                store.selectedRigID = -1
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Local AI · \(localModel.status.title)")
            }
            Divider()
        }

        if let rigs = store.snapshot?.rigs {
            ForEach(rigs) { rig in
                Button {
                    store.sidebarSelection = .rig(rig.id)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("Rig \(rig.id) · \(rig.holder ?? "free") · \(rig.devIsRunning ? "live :\(rig.devPort)" : "stopped")")
                }
            }
        } else {
            Text("Reading rigs…")
        }

        Divider()
        Button("Open Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") {
            Task { await store.refresh() }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
