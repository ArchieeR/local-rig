import Foundation

struct ProcessTable: Sendable {
    let processes: [Int: LocalProcess]

    static func parse(_ output: String) -> ProcessTable {
        var parsed: [Int: LocalProcess] = [:]
        for line in output.split(whereSeparator: \ .isNewline) {
            let fields = line.split(maxSplits: 5, whereSeparator: \ .isWhitespace)
            guard fields.count == 6,
                  let pid = Int(fields[0]),
                  let parentPID = Int(fields[1]),
                  let residentKB = UInt64(fields[2]),
                  let cpuPercent = Double(fields[3]) else { continue }
            parsed[pid] = LocalProcess(
                pid: pid,
                parentPID: parentPID,
                residentBytes: residentKB * 1_024,
                cpuPercent: cpuPercent,
                elapsed: String(fields[4]),
                command: String(fields[5])
            )
        }
        return ProcessTable(processes: parsed)
    }

    func processTree(rootPIDs: Set<Int>) -> [LocalProcess] {
        var included = rootPIDs
        var changed = true
        while changed {
            changed = false
            for process in processes.values where included.contains(process.parentPID) && !included.contains(process.pid) {
                included.insert(process.pid)
                changed = true
            }
        }
        return included.compactMap { processes[$0] }.sorted { $0.pid < $1.pid }
    }

    func residentBytes(rootPIDs: Set<Int>) -> UInt64 {
        processTree(rootPIDs: rootPIDs).reduce(0) { $0 + $1.residentBytes }
    }

    func descendants(of pid: Int) -> [LocalProcess] {
        processTree(rootPIDs: [pid])
    }

    func hasAncestor(_ pid: Int, matching predicate: (LocalProcess) -> Bool) -> Bool {
        var current = processes[pid]
        var seen: Set<Int> = []
        while let process = current, !seen.contains(process.pid) {
            seen.insert(process.pid)
            guard let parent = processes[process.parentPID] else { return false }
            if predicate(parent) { return true }
            current = parent
        }
        return false
    }
}

struct ListeningPorts: Sendable {
    let processIDsByPort: [Int: Set<Int>]

    static func parse(_ output: String) -> ListeningPorts {
        var byPort: [Int: Set<Int>] = [:]
        var currentPID: Int?

        for rawLine in output.split(whereSeparator: \ .isNewline) {
            let line = String(rawLine)
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                currentPID = Int(value)
            case "n":
                guard let currentPID,
                      let portText = value.split(separator: ":").last,
                      let port = Int(portText) else { continue }
                byPort[port, default: []].insert(currentPID)
            default:
                continue
            }
        }
        return ListeningPorts(processIDsByPort: byPort)
    }

    func processIDs(on port: Int) -> Set<Int> {
        processIDsByPort[port] ?? []
    }

    func ports(ownedBy processIDs: Set<Int>) -> [Int] {
        processIDsByPort.compactMap { port, owners in
            owners.isDisjoint(with: processIDs) ? nil : port
        }.sorted()
    }
}

struct ProcessInspectionService: Sendable {
    private let runner = ProcessRunner()

    func capture() async throws -> (ProcessTable, ListeningPorts) {
        async let processResult = runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,rss=,%cpu=,etime=,command="]
        )
        async let portResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        )

        let (processes, ports) = try await (processResult, portResult)
        return (
            ProcessTable.parse(processes.standardOutput),
            ListeningPorts.parse(ports.standardOutput)
        )
    }
}
