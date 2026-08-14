import AppKit
import SwiftUI

final class LocalRigAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
@MainActor
struct LocalRigApp: App {
    @NSApplicationDelegateAdaptor(LocalRigAppDelegate.self) private var appDelegate
    @StateObject private var store: RigStore

    init() {
        let store = RigStore()
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        Window("Local Rig", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Rig") {
                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")

                Button("Run Doctor") {
                    Task { await store.run(.doctor) }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(store.selectedRig == nil)

                Button("Create Agent Handoff") {
                    store.createAgentHandoff()
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(store.selectedRig == nil)
            }
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra("Local Rig", systemImage: store.menuBarSymbol) {
            MenuBarView(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}
