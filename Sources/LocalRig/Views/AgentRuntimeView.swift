import SwiftUI

private enum SessionGrouping: String, CaseIterable, Identifiable {
    case agent
    case flat

    var id: Self { self }
    var title: String {
        switch self {
        case .agent: "Agent"
        case .flat: "None"
        }
    }
}

private enum SessionSort: String, CaseIterable, Identifiable {
    case attention
    case agent
    case memory
    case age

    var id: Self { self }
    var title: String {
        switch self {
        case .attention: "Attention"
        case .agent: "Agent"
        case .memory: "Memory"
        case .age: "Age"
        }
    }
}

private struct SessionSection: Identifiable {
    let id: String
    let family: AgentFamily?
    let sessions: [AgentSessionGroup]
}

private struct SessionTerminationTarget {
    let session: AgentSessionGroup
    let kind: AgentSessionTerminationKind
}

struct AgentRuntimeView: View {
    @ObservedObject var store: RigStore
    let snapshot: DashboardSnapshot
    @State private var showOnlyAttention = false
    @State private var terminationTarget: SessionTerminationTarget?
    @StateObject private var expansionStore = RuntimeExpansionStore()
    @AppStorage("agentRuntime.sessionGrouping") private var sessionGrouping = SessionGrouping.agent
    @AppStorage("agentRuntime.sessionSort") private var sessionSort = SessionSort.attention

    private var runtime: AgentRuntimeSnapshot { snapshot.agentRuntime }
    private var visibleSessions: [AgentSessionGroup] {
        showOnlyAttention ? runtime.sessions.filter(\.isStaleCandidate) : runtime.sessions
    }
    private var visibleUnassigned: [RuntimeComponent] {
        showOnlyAttention ? runtime.unassignedComponents.filter(\.isStaleCandidate) : runtime.unassignedComponents
    }
    private var sessionSections: [SessionSection] {
        let sortedSessions = visibleSessions.sorted(by: sessionComesBefore)
        guard sessionGrouping == .agent else {
            return [SessionSection(id: "all", family: nil, sessions: sortedSessions)]
        }

        let familyOrder: [AgentFamily] = [.codex, .claudeCode, .claudeDesktop]
        return familyOrder.compactMap { family in
            let sessions = sortedSessions.filter { $0.family == family }
            guard !sessions.isEmpty else { return nil }
            return SessionSection(id: family.rawValue, family: family, sessions: sessions)
        }
    }
    private var expansionIdentity: [String] {
        runtime.sessions.map { "session:\($0.id)" }
            + runtime.sessions.flatMap { $0.components.map { "component:\($0.rootPID)" } }
            + runtime.unassignedComponents.map { "component:\($0.rootPID)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                metrics

                if runtime.staleCandidateCount > 0 {
                    attentionBanner
                }

                if !runtime.hosts.isEmpty {
                    hostsCard
                }

                sectionHeader

                if visibleSessions.isEmpty && visibleUnassigned.isEmpty {
                    ContentUnavailableView(
                        showOnlyAttention ? "No stale candidates" : "No agent sessions detected",
                        systemImage: showOnlyAttention ? "checkmark.circle" : "terminal",
                        description: Text(showOnlyAttention ? "Nothing currently meets the conservative review rules." : "Codex and Claude process cohorts will appear here when they are running.")
                    )
                    .frame(minHeight: 220)
                } else {
                    ForEach(sessionSections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if let family = section.family {
                                agentSectionHeader(family: family, sessions: section.sessions)
                            }
                            ForEach(section.sessions) { session in
                                SessionRuntimeCard(
                                    session: session,
                                    isExpanded: sessionExpansionBinding(for: session.id),
                                    componentExpansionBinding: componentExpansionBinding,
                                    isCleaning: store.cleaningSessionIDs.contains(session.id),
                                    terminationKind: terminationKind(for: session),
                                    onTerminate: {
                                        guard let kind = terminationKind(for: session) else { return }
                                        terminationTarget = SessionTerminationTarget(session: session, kind: kind)
                                    }
                                )
                            }
                        }
                    }

                    if !visibleUnassigned.isEmpty {
                        Text("Unattributed workspace processes")
                            .font(.title3.weight(.semibold))
                            .padding(.top, 4)
                        ForEach(visibleUnassigned) { component in
                            RuntimeComponentCard(
                                component: component,
                                isExpanded: componentExpansionBinding(component.rootPID)
                            )
                        }
                    }
                }

                Text("Session counts are inferred from live task runtimes. Claude Desktop does not expose its open-chat count through the macOS process table. Physical occupied memory includes reclaimable file cache; the pressure status indicates whether macOS is actually constrained.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .navigationTitle("Agent Runtimes")
        .onChange(of: expansionIdentity, initial: true) { _, _ in
            expansionStore.reconcile(
                sessionIDs: Set(runtime.sessions.map(\.id)),
                componentPIDs: Set(
                    runtime.sessions.flatMap { $0.components.map(\.rootPID) }
                        + runtime.unassignedComponents.map(\.rootPID)
                )
            )
        }
        .confirmationDialog(
            terminationDialogTitle,
            isPresented: Binding(
                get: { terminationTarget != nil },
                set: { if !$0 { terminationTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let terminationTarget {
                Button(terminationButtonTitle(terminationTarget), role: .destructive) {
                    let target = terminationTarget
                    self.terminationTarget = nil
                    Task {
                        await store.terminateAgentSession(target.session, kind: target.kind)
                    }
                }
            }
            Button("Cancel", role: .cancel) { terminationTarget = nil }
        } message: {
            Text(terminationConfirmationMessage)
        }
    }

    private func sessionExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expansionStore.isSessionExpanded(id) },
            set: { expansionStore.setSession(id, expanded: $0) }
        )
    }

    private func componentExpansionBinding(_ rootPID: Int) -> Binding<Bool> {
        Binding(
            get: { expansionStore.isComponentExpanded(rootPID) },
            set: { expansionStore.setComponent(rootPID, expanded: $0) }
        )
    }

    private func terminationKind(for session: AgentSessionGroup) -> AgentSessionTerminationKind? {
        if session.family == .codex && session.isStaleCandidate { return .staleCleanup }
        if session.family == .codex || session.family == .claudeCode { return .userRequested }
        return nil
    }

    private var terminationDialogTitle: String {
        guard let target = terminationTarget else { return "End agent session?" }
        return switch target.kind {
        case .staleCleanup: "Clean up stale Codex cohort?"
        case .userRequested: "End \(target.session.title)?"
        }
    }

    private func terminationButtonTitle(_ target: SessionTerminationTarget) -> String {
        let processCount = Set(target.session.components.flatMap { $0.processes.map(\.pid) }).count
        return switch target.kind {
        case .staleCleanup:
            "Clean up at least \(processCount) observed processes · ~\(RigFormatters.memory(target.session.residentBytes))"
        case .userRequested:
            "End session · at least \(processCount) observed processes · ~\(RigFormatters.memory(target.session.residentBytes))"
        }
    }

    private var terminationConfirmationMessage: String {
        guard let target = terminationTarget else { return "" }
        let ports = Set(target.session.components.flatMap(\.listeningPorts)).sorted()
        let listenerWarning = ports.isEmpty
            ? ""
            : " This cohort still has listeners on \(ports.map { ":\($0)" }.joined(separator: ", "))."
        switch target.kind {
        case .staleCleanup:
            return "Local Rig will re-scan the live process tree and abort if a Codex app-server has returned. If it is still stale, it sends SIGTERM to this cohort only. It never force-kills survivors.\(listenerWarning)"
        case .userRequested:
            return "You are explicitly ending a session that Rig does not consider stale. Rig will re-scan and verify the same task runtime PID and command before sending SIGTERM to that session and its descendants. Its active turn and unsaved terminal state may be lost. Rig aborts if the cohort owns a shared emulator or local-model listener; shared app hosts and unrelated processes are excluded. Survivors are never force-killed.\(listenerWarning)"
        }
    }

    private func sessionComesBefore(_ lhs: AgentSessionGroup, _ rhs: AgentSessionGroup) -> Bool {
        switch sessionSort {
        case .attention:
            if lhs.isStaleCandidate != rhs.isStaleCandidate { return lhs.isStaleCandidate }
            if lhs.residentBytes != rhs.residentBytes { return lhs.residentBytes > rhs.residentBytes }
        case .agent:
            let order: [AgentFamily: Int] = [.codex: 0, .claudeCode: 1, .claudeDesktop: 2]
            if lhs.family != rhs.family { return order[lhs.family, default: 99] < order[rhs.family, default: 99] }
            if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        case .memory:
            if lhs.residentBytes != rhs.residentBytes { return lhs.residentBytes > rhs.residentBytes }
        case .age:
            if lhs.ageSeconds != rhs.ageSeconds { return lhs.ageSeconds > rhs.ageSeconds }
        }
        return lhs.id < rhs.id
    }

    private func agentSectionHeader(family: AgentFamily, sessions: [AgentSessionGroup]) -> some View {
        let observedSessions = sessions.reduce(0) { $0 + $1.estimatedSessionCount }
        let mcpCount = sessions.reduce(0) { $0 + $1.mcpCount }
        let residentBytes = sessions.reduce(UInt64(0)) { $0 + $1.residentBytes }
        return HStack(spacing: 8) {
            Label(family.rawValue, systemImage: family.systemImage)
                .font(.headline)
            Text("\(observedSessions) session\(observedSessions == 1 ? "" : "s") · \(mcpCount) MCPs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(RigFormatters.memory(residentBytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Developer Activity Monitor")
                    .font(.largeTitle.weight(.semibold))
                Text("Codex and Claude task cohorts, their MCP stacks, Node processes, RAM, CPU, ports and repository attribution.")
                    .foregroundStyle(.secondary)
                Text("Snapshot \(RigFormatters.timestamp(snapshot.capturedAt)) · one shared process scan per refresh")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Send review to agent", systemImage: "paperplane") {
                store.createProcessReviewHandoff()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var metrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                RuntimeMetricCard(title: "Observed sessions", value: "\(runtime.estimatedSessionCount)", detail: "\(runtime.activeSessionCount) active", image: "rectangle.stack.badge.person.crop")
                RuntimeMetricCard(title: "MCP instances", value: "\(runtime.mcpCount)", detail: "root servers", image: "server.rack")
                RuntimeMetricCard(title: "Node processes", value: "\(runtime.nodeProcessCount)", detail: "inside tracked groups", image: "shippingbox")
            }
            GridRow {
                RuntimeMetricCard(title: "Agent footprint", value: RigFormatters.memory(runtime.residentBytes), detail: "Codex + Claude app trees", image: "memorychip")
                RuntimeMetricCard(title: "Possible stale", value: "\(runtime.staleCandidateCount)", detail: "review before cleanup", image: "exclamationmark.triangle")
                RuntimeMetricCard(
                    title: "Physical occupied",
                    value: RigFormatters.memory(snapshot.systemMemory.physicalOccupiedBytes),
                    detail: "of \(RigFormatters.memory(snapshot.systemMemory.totalBytes)) · \(snapshot.systemMemory.pressureStatus.lowercased()) pressure",
                    image: "gauge.with.dots.needle.50percent"
                )
            }
        }
    }

    private var attentionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(runtime.staleCandidateCount) process group\(runtime.staleCandidateCount == 1 ? "" : "s") need review")
                    .font(.headline)
                Text("The app flags missing task runtimes, launchd-adopted MCPs, excess MCP copies, and workspace dev helpers with no listener. Confirmed cleanup re-checks the cohort live and uses graceful termination only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Only attention", isOn: $showOnlyAttention)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.28)))
    }

    private var hostsCard: some View {
        GroupBox("Agent applications") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(runtime.hosts) { host in
                    GridRow {
                        Label(host.family.rawValue, systemImage: host.family.systemImage)
                        Text("PID \(host.rootPID)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(host.processCount) processes")
                            .foregroundStyle(.secondary)
                        Text(RigFormatters.memory(host.residentBytes))
                            .monospacedDigit()
                        Text(String(format: "%.1f%% CPU", host.cpuPercent))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 12) {
            Text(showOnlyAttention ? "Attention queue" : "Task cohorts")
                .font(.title2.weight(.semibold))
            Spacer()
            if runtime.staleCandidateCount == 0 {
                Toggle("Only attention", isOn: $showOnlyAttention)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Picker("Group", selection: $sessionGrouping) {
                ForEach(SessionGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Picker("Sort", selection: $sessionSort) {
                ForEach(SessionSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

private struct SessionRuntimeCard: View {
    let session: AgentSessionGroup
    @Binding var isExpanded: Bool
    let componentExpansionBinding: (Int) -> Binding<Bool>
    let isCleaning: Bool
    let terminationKind: AgentSessionTerminationKind?
    let onTerminate: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        sessionHeader
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse session" : "Expand session")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                    if let terminationKind {
                        Button {
                            onTerminate()
                        } label: {
                            if isCleaning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                switch terminationKind {
                                case .staleCleanup:
                                    Label("Clean up…", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                case .userRequested:
                                    Label("End session…", systemImage: "stop.circle")
                                        .labelStyle(.iconOnly)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCleaning)
                        .accessibilityLabel(terminationKind == .staleCleanup
                            ? "Clean up stale session"
                            : "End session")
                        .help(terminationKind == .staleCleanup
                            ? "Re-check and gracefully stop this stale cohort"
                            : "End this selected session and its owned child processes")
                    }
                }

                if isExpanded {
                    sessionDetails
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: session.family.systemImage)
                .foregroundStyle(session.isStaleCandidate ? .orange : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.headline)
                Text("\(session.activeSessionCount) active · \(session.inactiveSessionCount) inactive · \(session.mcpCount) MCPs · \(session.nodeProcessCount) Node")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(RigFormatters.duration(session.ageSeconds))
                .foregroundStyle(.secondary)
            Text(RigFormatters.memory(session.residentBytes))
                .font(.headline.monospacedDigit())
            if session.isStaleCandidate {
                Text("REVIEW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.repositoryPaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.repositoryPaths, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            ForEach(session.staleReasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(session.components) { component in
                RuntimeComponentRow(
                    component: component,
                    isExpanded: componentExpansionBinding(component.rootPID)
                )
            }
        }
        .padding(.top, 10)
    }
}

private struct RuntimeComponentCard: View {
    let component: RuntimeComponent
    @Binding var isExpanded: Bool

    var body: some View {
        GroupBox {
            RuntimeComponentRow(component: component, isExpanded: $isExpanded)
        }
    }
}

private struct RuntimeComponentRow: View {
    let component: RuntimeComponent
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                componentHeader
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse processes" : "Expand processes")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(component.staleReasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(component.processes) { process in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(process.pid)")
                                .frame(width: 54, alignment: .trailing)
                            Text(RigFormatters.memory(process.residentBytes))
                                .frame(width: 72, alignment: .trailing)
                            Text(String(format: "%.1f%%", process.cpuPercent))
                                .frame(width: 50, alignment: .trailing)
                            Text(LogSanitizer.sanitize(process.command, maximumLines: 1))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(LogSanitizer.sanitize(process.command, maximumLines: 1))
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var componentHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: component.kind == .browser ? "globe" : component.kind == .mcp ? "server.rack" : "gearshape.2")
                .foregroundStyle(component.isStaleCandidate ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                Text(component.repositoryPath ?? component.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !component.listeningPorts.isEmpty {
                Text(component.listeningPorts.map { ":\($0)" }.joined(separator: " "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(component.processes.count) proc")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(RigFormatters.memory(component.residentBytes))
                .font(.body.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
            Text(String(format: "%.1f%%", component.cpuPercent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct RuntimeMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let image: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: image)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
