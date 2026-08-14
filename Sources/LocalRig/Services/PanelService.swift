import AppKit
import Foundation

@MainActor
enum PanelService {
    static func chooseWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the development workspace folder"
        panel.message = "The folder must contain scripts/qa-rig.sh or scripts/rig2.sh."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
