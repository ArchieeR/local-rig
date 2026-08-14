import Foundation

@MainActor
final class RuntimeExpansionStore: ObservableObject {
    private enum Keys {
        static let collapsedSessions = "agentRuntime.collapsedSessionIDs"
        static let expandedComponents = "agentRuntime.expandedComponentPIDs"
    }

    @Published private(set) var collapsedSessionIDs: Set<String>
    @Published private(set) var expandedComponentPIDs: Set<Int>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedSessionIDs = Set(defaults.stringArray(forKey: Keys.collapsedSessions) ?? [])
        expandedComponentPIDs = Set(
            (defaults.stringArray(forKey: Keys.expandedComponents) ?? []).compactMap(Int.init)
        )
    }

    func isSessionExpanded(_ id: String) -> Bool {
        !collapsedSessionIDs.contains(id)
    }

    func setSession(_ id: String, expanded: Bool) {
        if expanded {
            collapsedSessionIDs.remove(id)
        } else {
            collapsedSessionIDs.insert(id)
        }
        defaults.set(collapsedSessionIDs.sorted(), forKey: Keys.collapsedSessions)
    }

    func isComponentExpanded(_ rootPID: Int) -> Bool {
        expandedComponentPIDs.contains(rootPID)
    }

    func setComponent(_ rootPID: Int, expanded: Bool) {
        if expanded {
            expandedComponentPIDs.insert(rootPID)
        } else {
            expandedComponentPIDs.remove(rootPID)
        }
        defaults.set(expandedComponentPIDs.sorted().map(String.init), forKey: Keys.expandedComponents)
    }

    func reconcile(sessionIDs: Set<String>, componentPIDs: Set<Int>) {
        let reconciledSessions = collapsedSessionIDs.intersection(sessionIDs)
        let reconciledComponents = expandedComponentPIDs.intersection(componentPIDs)
        guard reconciledSessions != collapsedSessionIDs || reconciledComponents != expandedComponentPIDs else {
            return
        }
        collapsedSessionIDs = reconciledSessions
        expandedComponentPIDs = reconciledComponents
        defaults.set(collapsedSessionIDs.sorted(), forKey: Keys.collapsedSessions)
        defaults.set(expandedComponentPIDs.sorted().map(String.init), forKey: Keys.expandedComponents)
    }
}
