import Foundation

struct AgentRuntimeAnalyzer: Sendable {
    private let staleAge: UInt64 = 10 * 60

    func analyze(
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        workspaceRoot: URL,
        codexSessionMetadataByPID: [Int: CodexCohortMetadata] = [:],
        claudeSessionTitlesByPID: [Int: String] = [:]
    ) -> AgentRuntimeSnapshot {
        let codexHosts = processTable.processes.values.filter(isCodexHost).sorted { $0.pid < $1.pid }
        let claudeDesktopHosts = processTable.processes.values.filter(isClaudeDesktopHost).sorted { $0.pid < $1.pid }

        var sessions: [AgentSessionGroup] = []
        var assignedPIDs: Set<Int> = []

        for host in codexHosts {
            let groups = codexGroups(
                host: host,
                processTable: processTable,
                listeningPorts: listeningPorts,
                workspaceRoot: workspaceRoot,
                sessionMetadataByPID: codexSessionMetadataByPID
            )
            sessions.append(contentsOf: groups)
            assignedPIDs.formUnion(groups.flatMap { $0.components.flatMap { $0.processes.map(\.pid) } })
        }

        let claudeGroups = claudeCodeGroups(
            processTable: processTable,
            listeningPorts: listeningPorts,
            workspaceRoot: workspaceRoot,
            sessionTitlesByPID: claudeSessionTitlesByPID
        )
        sessions.append(contentsOf: claudeGroups)
        assignedPIDs.formUnion(claudeGroups.flatMap { $0.components.flatMap { $0.processes.map(\.pid) } })

        let devServers = devServers(
            processTable: processTable,
            listeningPorts: listeningPorts,
            sessions: sessions,
            workspaceRoot: workspaceRoot
        )
        assignedPIDs.formUnion(devServers.flatMap { $0.processes.map(\.pid) })

        let unassigned = unassignedComponents(
            excluding: assignedPIDs,
            processTable: processTable,
            listeningPorts: listeningPorts,
            workspaceRoot: workspaceRoot
        )

        let hostProcesses = (codexHosts.map { ($0, AgentFamily.codex) }
            + claudeDesktopHosts.map { ($0, AgentFamily.claudeDesktop) })
            .map { process, family -> AgentHostSnapshot in
                let tree = processTable.descendants(of: process.pid)
                return AgentHostSnapshot(
                    family: family,
                    rootPID: process.pid,
                    processCount: tree.count,
                    residentBytes: tree.reduce(0) { $0 + $1.residentBytes },
                    cpuPercent: tree.reduce(0) { $0 + $1.cpuPercent }
                )
            }

        return AgentRuntimeSnapshot(
            hosts: hostProcesses.sorted { $0.family.rawValue < $1.family.rawValue },
            sessions: sessions.sorted {
                if $0.isStaleCandidate != $1.isStaleCandidate { return $0.isStaleCandidate }
                return $0.ageSeconds < $1.ageSeconds
            },
            unassignedComponents: unassigned.sorted {
                if $0.isStaleCandidate != $1.isStaleCandidate { return $0.isStaleCandidate }
                return $0.residentBytes > $1.residentBytes
            },
            devServers: devServers.sorted { $0.port < $1.port }
        )
    }

    private func devServers(
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        sessions: [AgentSessionGroup],
        workspaceRoot: URL
    ) -> [DevServerSnapshot] {
        var rootsByKey: [String: (port: Int, root: LocalProcess, listeners: Set<Int>)] = [:]

        for (port, listenerPIDs) in listeningPorts.processIDsByPort {
            for listenerPID in listenerPIDs {
                guard let root = devServerRoot(listenerPID: listenerPID, processTable: processTable) else {
                    continue
                }
                let key = "\(port)-\(root.pid)"
                if var existing = rootsByKey[key] {
                    existing.listeners.insert(listenerPID)
                    rootsByKey[key] = existing
                } else {
                    rootsByKey[key] = (port, root, [listenerPID])
                }
            }
        }

        return rootsByKey.values.map { value in
            let tree = processTable.descendants(of: value.root.pid)
            let treePIDs = Set(tree.map(\.pid))
            let ownership = devServerOwnership(
                port: value.port,
                processIDs: treePIDs,
                root: value.root,
                sessions: sessions,
                processTable: processTable
            )
            return DevServerSnapshot(
                port: value.port,
                rootPID: value.root.pid,
                listenerPIDs: value.listeners.sorted(),
                processes: tree,
                repositoryPath: devServerRepositoryPath(in: tree, workspaceRoot: workspaceRoot),
                ownerKind: ownership.kind,
                ownerLabel: ownership.label,
                sessionID: ownership.sessionID,
                ageSeconds: elapsedSeconds(value.root.elapsed)
            )
        }
    }

    private func devServerRoot(
        listenerPID: Int,
        processTable: ProcessTable
    ) -> LocalProcess? {
        var current = processTable.processes[listenerPID]
        var highestMatch: LocalProcess?
        var seen: Set<Int> = []
        while let process = current, !seen.contains(process.pid) {
            seen.insert(process.pid)
            if isDevServerProcess(process) { highestMatch = process }
            current = processTable.processes[process.parentPID]
        }
        return highestMatch
    }

    private func devServerOwnership(
        port: Int,
        processIDs: Set<Int>,
        root: LocalProcess,
        sessions: [AgentSessionGroup],
        processTable: ProcessTable
    ) -> (kind: DevServerOwnerKind, label: String, sessionID: String?) {
        if (3_000...3_004).contains(port) {
            return (.rig, "Rig \(port - 2_999) · reserved port", nil)
        }

        for session in sessions {
            var ownedPIDs = Set(session.components.flatMap { $0.processes.map(\.pid) })
            for taskPID in session.taskRuntimePIDs {
                ownedPIDs.formUnion(processTable.descendants(of: taskPID).map(\.pid))
            }
            if !ownedPIDs.isDisjoint(with: processIDs) {
                return (.agentSession, session.title, session.id)
            }
        }

        if processTable.hasAncestor(root.pid, matching: isClaudeDesktopHost) {
            return (.claudeDesktop, "Claude Desktop · chat unavailable", nil)
        }
        if processTable.hasAncestor(root.pid, matching: isCodexHost) {
            return (.unassigned, "Codex · unmatched session", nil)
        }
        if isShellProcess(root) || processTable.hasAncestor(root.pid, matching: isShellProcess) {
            return (.terminal, "Terminal / manual", nil)
        }
        return (.unassigned, "Unattributed", nil)
    }

    private func devServerRepositoryPath(
        in processes: [LocalProcess],
        workspaceRoot: URL
    ) -> String? {
        for process in processes {
            let command = process.command.removingPercentEncoding ?? process.command
            guard let marker = command.range(of: "/node_modules/") else { continue }
            let prefix = command[..<marker.lowerBound]
            let pathStart: String.Index
            if let separator = prefix.range(of: " /", options: .backwards) {
                pathStart = command.index(after: separator.lowerBound)
            } else if prefix.first == "/" {
                pathStart = command.startIndex
            } else {
                continue
            }
            let path = String(command[pathStart..<marker.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            if path.hasPrefix("/") { return path }
        }
        return repositoryPaths(in: processes, workspaceRoot: workspaceRoot).first
    }

    private func codexGroups(
        host: LocalProcess,
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        workspaceRoot: URL,
        sessionMetadataByPID: [Int: CodexCohortMetadata]
    ) -> [AgentSessionGroup] {
        let directRoots = processTable.processes.values.filter {
            $0.parentPID == host.pid && isCodexCohortRoot($0)
        }
        let sentinels = directRoots.filter { $0.command.lowercased().contains("node_repl") }
            .sorted { elapsedSeconds($0.elapsed) > elapsedSeconds($1.elapsed) }

        var cohorts: [[LocalProcess]] = []
        for sentinel in sentinels {
            let age = elapsedSeconds(sentinel.elapsed)
            if let index = cohorts.firstIndex(where: {
                guard let reference = $0.first else { return false }
                return absoluteDifference(age, elapsedSeconds(reference.elapsed)) <= 3
            }) {
                cohorts[index].append(sentinel)
            } else {
                cohorts.append([sentinel])
            }
        }

        return cohorts.map { cohortSentinels in
            let referenceAge = cohortSentinels.map { elapsedSeconds($0.elapsed) }.max() ?? 0
            let cohortRootPID = cohortSentinels.map(\.pid).min() ?? host.pid
            let sessionMetadata = cohortSentinels.compactMap { sessionMetadataByPID[$0.pid] }.first
            let roots = directRoots.filter {
                absoluteDifference(referenceAge, elapsedSeconds($0.elapsed)) <= 4
            }
            let activeCount = cohortSentinels.filter { sentinel in
                processTable.descendants(of: sentinel.pid).contains {
                    $0.pid != sentinel.pid && $0.command.contains("codex app-server")
                }
            }.count
            let allProcesses = roots.flatMap { processTable.descendants(of: $0.pid) }
            let paths = workingDirectories(
                in: allProcesses
            )
            let components = makeComponents(
                roots: roots,
                processTable: processTable,
                listeningPorts: listeningPorts,
                workspaceRoot: workspaceRoot,
                staleReasons: []
            )
            var staleReasons: [String] = []
            if activeCount == 0 && referenceAge >= staleAge && sessionMetadata?.isTurnActive != true {
                staleReasons.append("No live Codex app-server remains in this task cohort")
                if components.contains(where: { $0.kind == .mcp || $0.kind == .browser }) {
                    staleReasons.append("MCP processes are still resident; review before cleanup")
                }
            }
            let duplicationEligibleNames: Set<String> = ["Firebase MCP", "Firefox DevTools", "Local Rig MCP"]
            let duplicateNames = Dictionary(grouping: components.filter { duplicationEligibleNames.contains($0.name) }, by: \.name)
                .filter { $0.value.count > cohortSentinels.count }
                .keys.sorted()
            if !duplicateNames.isEmpty {
                staleReasons.append("More MCP instances than task runtimes: \(duplicateNames.joined(separator: ", "))")
            }
            let label = sessionMetadata?.title
                ?? paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "task cohort"
            let effectiveActiveCount = sessionMetadata?.isTurnActive == true ? max(1, activeCount) : activeCount
            return AgentSessionGroup(
                id: "codex-\(host.pid)-\(cohortRootPID)",
                family: .codex,
                title: "Codex · \(label)",
                hostPID: host.pid,
                taskRuntimePIDs: cohortSentinels.map(\.pid).sorted(),
                activeSessionCount: effectiveActiveCount,
                inactiveSessionCount: max(0, cohortSentinels.count - effectiveActiveCount),
                ageSeconds: referenceAge,
                repositoryPaths: paths,
                components: components,
                staleReasons: staleReasons
            )
        }
    }

    private func claudeCodeGroups(
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        workspaceRoot: URL,
        sessionTitlesByPID: [Int: String]
    ) -> [AgentSessionGroup] {
        let roots = processTable.processes.values.filter { process in
            isClaudeCode(process) && !processTable.hasAncestor(process.pid, matching: isClaudeCode)
        }
        return roots.map { root in
            let tree = processTable.descendants(of: root.pid)
            let treeIDs = Set(tree.map(\.pid))
            let mcpCandidates = tree.filter { $0.pid != root.pid && isKnownMCP($0) }
            let mcpIDs = Set(mcpCandidates.map(\.pid))
            let mcpRoots = mcpCandidates.filter { candidate in
                !processTable.hasAncestor(candidate.pid) { ancestor in
                    treeIDs.contains(ancestor.pid) && mcpIDs.contains(ancestor.pid)
                }
            }
            var components = [RuntimeComponent(
                rootPID: root.pid,
                name: "Claude Code runtime",
                kind: .taskRuntime,
                processes: [root],
                repositoryPath: workingDirectories(in: tree).first,
                listeningPorts: listeningPorts.ports(ownedBy: [root.pid]),
                staleReasons: []
            )]
            components.append(contentsOf: makeComponents(
                roots: mcpRoots,
                processTable: processTable,
                listeningPorts: listeningPorts,
                workspaceRoot: workspaceRoot,
                staleReasons: []
            ))
            let paths = workingDirectories(in: tree)
            let label = sessionTitlesByPID[root.pid]
                ?? paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "session"
            return AgentSessionGroup(
                id: "claude-\(root.pid)",
                family: .claudeCode,
                title: "Claude Code · \(label)",
                hostPID: root.pid,
                taskRuntimePIDs: [root.pid],
                activeSessionCount: 1,
                inactiveSessionCount: 0,
                ageSeconds: elapsedSeconds(root.elapsed),
                repositoryPaths: paths,
                components: components,
                staleReasons: []
            )
        }
    }

    private func unassignedComponents(
        excluding assignedPIDs: Set<Int>,
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        workspaceRoot: URL
    ) -> [RuntimeComponent] {
        let candidates = processTable.processes.values.filter { process in
            !assignedPIDs.contains(process.pid)
                && (isKnownMCP(process) || isWorkspaceDevProcess(process, workspaceRoot: workspaceRoot))
        }
        let candidateIDs = Set(candidates.map(\.pid))
        let roots = candidates.filter { !candidateIDs.contains($0.parentPID) }

        return roots.map { root in
            let tree = processTable.descendants(of: root.pid)
            let ids = Set(tree.map(\.pid))
            let ports = listeningPorts.ports(ownedBy: ids)
            let age = elapsedSeconds(root.elapsed)
            var reasons: [String] = []
            if age >= staleAge && root.parentPID == 1 {
                reasons.append("Parent session has exited; process is adopted by launchd")
            }
            if age >= staleAge && ports.isEmpty && isWorkspaceDevProcess(root, workspaceRoot: workspaceRoot) {
                reasons.append("Workspace dev helper has no listening port")
            }
            if age >= staleAge && isKnownMCP(root) && !hasAgentAncestor(root, processTable: processTable) {
                reasons.append("MCP process is not attributable to a live Codex or Claude session")
            }
            return component(
                root: root,
                tree: tree,
                ports: ports,
                workspaceRoot: workspaceRoot,
                staleReasons: reasons
            )
        }
    }

    private func makeComponents(
        roots: [LocalProcess],
        processTable: ProcessTable,
        listeningPorts: ListeningPorts,
        workspaceRoot: URL,
        staleReasons: [String]
    ) -> [RuntimeComponent] {
        var seen: Set<Int> = []
        return roots.sorted { $0.pid < $1.pid }.compactMap { root in
            guard !seen.contains(root.pid) else { return nil }
            let tree = processTable.descendants(of: root.pid)
            seen.formUnion(tree.map(\.pid))
            return component(
                root: root,
                tree: tree,
                ports: listeningPorts.ports(ownedBy: Set(tree.map(\.pid))),
                workspaceRoot: workspaceRoot,
                staleReasons: staleReasons
            )
        }
    }

    private func component(
        root: LocalProcess,
        tree: [LocalProcess],
        ports: [Int],
        workspaceRoot: URL,
        staleReasons: [String]
    ) -> RuntimeComponent {
        let classification = classify(root)
        return RuntimeComponent(
            rootPID: root.pid,
            name: classification.name,
            kind: classification.kind,
            processes: tree,
            repositoryPath: repositoryPaths(in: tree, workspaceRoot: workspaceRoot).first,
            listeningPorts: ports,
            staleReasons: staleReasons
        )
    }

    private func classify(_ process: LocalProcess) -> (name: String, kind: RuntimeComponentKind) {
        let command = process.command.lowercased()
        if command.contains("node_repl") || command.contains("codex app-server") {
            return ("Codex task runtime", .taskRuntime)
        }
        if command.contains("firefox-devtools-mcp") {
            return ("Firefox DevTools", .browser)
        }
        if command.contains("firebase-tools") && command.contains(" mcp") || command.contains("/firebase mcp") {
            return ("Firebase MCP", .mcp)
        }
        if command.contains("local-rig/mcp") || command.contains("rheos-rig/mcp") {
            return ("Local Rig MCP", .mcp)
        }
        if command.contains("backend-mcp-env") && command.contains("src/mcp/stdio") {
            return ("Rheos MCP (isolated env)", .mcp)
        }
        if command.contains("src/mcp/stdio") {
            return ("Rheos content MCP", .mcp)
        }
        if command.contains("mcp/server.bundle") {
            return ("Plugin MCP bundle", .mcp)
        }
        if command.contains("mcp/server") || command.contains("mcp-server") || command.contains(" mcp ") {
            return ("Local MCP", .mcp)
        }
        if command.contains("next dev") || command.contains("/.bin/vite") || command.contains("firebase-functions") {
            return ("Workspace dev process", .devServer)
        }
        return (URL(fileURLWithPath: process.command.split(separator: " ").first.map(String.init) ?? "process").lastPathComponent, .helper)
    }

    private func repositoryPaths(in processes: [LocalProcess], workspaceRoot: URL) -> [String] {
        var paths: Set<String> = []
        for process in processes {
            let command = process.command.removingPercentEncoding ?? process.command
            let prefix = workspaceRoot.path + "/"
            if let range = command.range(of: prefix) {
                let suffix = command[range.upperBound...]
                let component = String(suffix.prefix { character in
                    character != "/" && character != "\"" && character != ","
                        && character != "]" && character != "}" && !character.isWhitespace
                })
                if !component.isEmpty {
                    paths.insert(workspaceRoot.appendingPathComponent(component).path)
                } else {
                    paths.insert(workspaceRoot.path)
                }
            }
        }
        return paths.sorted()
    }

    private func workingDirectories(in processes: [LocalProcess]) -> [String] {
        var paths: Set<String> = []
        for process in processes {
            let command = process.command.removingPercentEncoding ?? process.command
            if let workingDirectory = value(after: "--working-dir ", in: command), workingDirectory.hasPrefix("/") {
                paths.insert(workingDirectory)
            }
        }
        return paths.sorted()
    }

    private func value(after marker: String, in command: String) -> String? {
        guard let range = command.range(of: marker, options: .backwards) else { return nil }
        return String(command[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func isCodexHost(_ process: LocalProcess) -> Bool {
        process.command.contains("/Contents/Resources/codex")
            && process.command.contains("app-server")
            && process.command.contains("analytics-default-enabled")
    }

    private func isClaudeDesktopHost(_ process: LocalProcess) -> Bool {
        process.command == "/Applications/Claude.app/Contents/MacOS/Claude"
    }

    private func isClaudeCode(_ process: LocalProcess) -> Bool {
        let executable = process.command.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        let basename = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        return !process.command.contains("/Applications/Claude.app")
            && (basename == "claude" || process.command.lowercased().contains("claude-code"))
    }

    private func isCodexCohortRoot(_ process: LocalProcess) -> Bool {
        process.command.lowercased().contains("node_repl") || isTrackedProcess(process)
    }

    private func isTrackedProcess(_ process: LocalProcess) -> Bool {
        isKnownMCP(process) || process.command.contains("codex app-server")
    }

    private func isKnownMCP(_ process: LocalProcess) -> Bool {
        let command = process.command.lowercased()
        let executable = command.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        guard !executable.hasPrefix("/applications/claude.app/") else { return false }
        return command.contains("firefox-devtools-mcp")
            || command.contains("firebase-tools") && command.contains(" mcp")
            || command.contains("/firebase mcp")
            || command.contains("local-rig/mcp")
            || command.contains("rheos-rig/mcp")
            || command.contains("src/mcp/stdio")
            || command.contains("mcp/server")
            || command.contains("mcp-server")
            || command.contains("server.bundle.mjs")
    }

    private func isWorkspaceDevProcess(_ process: LocalProcess, workspaceRoot: URL) -> Bool {
        let command = process.command.lowercased()
        return process.command.contains(workspaceRoot.path)
            && (command.contains("next dev") || command.contains("/.bin/vite") || command.contains("firebase-functions"))
    }

    private func isDevServerProcess(_ process: LocalProcess) -> Bool {
        let command = process.command.lowercased()
        return command.contains("next-server")
            || command.contains("next dev")
            || command.contains("/.bin/vite")
            || command.contains("npm run dev")
            || command.contains("npm --prefix") && command.contains(" run dev")
            || command.contains("pnpm run dev")
            || command.contains("pnpm dev")
            || command.contains("yarn dev")
            || command.contains("bun run dev")
            || command.contains("astro dev")
            || command.contains("nuxt dev")
            || command.contains("webpack serve")
            || command.contains("remix dev")
            || command.contains("expo start")
            || command.contains("react-scripts start")
    }

    private func isShellProcess(_ process: LocalProcess) -> Bool {
        let executable = process.command.split(whereSeparator: \ .isWhitespace).first.map(String.init) ?? ""
        let basename = URL(fileURLWithPath: executable).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return ["zsh", "bash", "fish", "sh"].contains(basename)
            || process.command.lowercased().hasPrefix("login -pf ")
    }

    private func hasAgentAncestor(_ process: LocalProcess, processTable: ProcessTable) -> Bool {
        processTable.hasAncestor(process.pid) { isCodexHost($0) || isClaudeCode($0) || isClaudeDesktopHost($0) }
    }

    private func elapsedSeconds(_ elapsed: String) -> UInt64 {
        let dayParts = elapsed.split(separator: "-", maxSplits: 1)
        let days: UInt64
        let clock: Substring
        if dayParts.count == 2 {
            days = UInt64(dayParts[0]) ?? 0
            clock = dayParts[1]
        } else {
            days = 0
            clock = Substring(elapsed)
        }
        let values = clock.split(separator: ":").compactMap { UInt64($0) }
        switch values.count {
        case 3: return days * 86_400 + values[0] * 3_600 + values[1] * 60 + values[2]
        case 2: return days * 86_400 + values[0] * 60 + values[1]
        case 1: return days * 86_400 + values[0]
        default: return days * 86_400
        }
    }

    private func absoluteDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }
}
