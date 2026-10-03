import Darwin
import Foundation
import NetbiteCore

/// `netbite processes [--json] [--flagged] [--tree] [--socket PATH]`
func processes(_ args: Arguments) throws {
    let socket = args.options["--socket"] ?? HelperPaths.socket
    var snapshot = ProcessCollector().snapshot()
    var throughHelper = false
    if geteuid() != 0, FileManager.default.fileExists(atPath: socket),
       case .processes(let fromHelper)? = try? HelperClient.send(.processes, socketPath: socket, timeout: 10) {
        snapshot = fromHelper
        throughHelper = true
    }

    let flags = Dictionary(uniqueKeysWithValues: snapshot.processes.map {
        ($0.pid, ProcessFlag.flags(forExecutable: $0.executablePath))
    })
    var shown = snapshot.processes
    if args.flags.contains("--flagged") { shown = shown.filter { !(flags[$0.pid] ?? []).isEmpty } }

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.netbite.encode(shown), as: UTF8.self))
        return
    }

    let depth = args.flags.contains("--tree") && !args.flags.contains("--flagged") ? treeOrder(&shown) : [:]
    print(pad("PID", 7) + pad("PPID", 7) + pad("USER", 12) + pad("CONN", 5) + "PROCESS")
    for process in shown {
        let indent = String(repeating: "  ", count: depth[process.pid] ?? 0)
        let connections = process.connections.map { String($0.count) } ?? "-"
        let command = process.arguments.isEmpty ? (process.executablePath ?? process.name) : process.arguments.joined(separator: " ")
        print(pad(String(process.pid), 7) + pad(String(process.parentPID), 7) + pad(process.userName ?? String(process.userID), 12)
              + pad(connections, 5) + indent + LogText.sanitized(command))
        for flag in (flags[process.pid] ?? []).sorted() {
            print(String(repeating: " ", count: 31) + indent + "! \(flag.label)")
        }
    }
    let flagged = flags.values.filter { !$0.isEmpty }.count
    print("\(snapshot.processes.count) processes, \(flagged) flagged.")
    if !throughHelper && geteuid() != 0 {
        print("Arguments and connections of other users' processes are hidden; install the helper or use sudo.")
    }
}

/// Reorders `processes` depth-first under their parents and returns each one's depth.
private func treeOrder(_ processes: inout [RunningProcess]) -> [Int32: Int] {
    let pids = Set(processes.map(\.pid))
    var children: [Int32: [RunningProcess]] = [:]
    var roots: [RunningProcess] = []
    for process in processes {
        if process.parentPID != process.pid, pids.contains(process.parentPID) {
            children[process.parentPID, default: []].append(process)
        } else {
            roots.append(process)
        }
    }
    var ordered: [RunningProcess] = []
    var depth: [Int32: Int] = [:]
    func visit(_ process: RunningProcess, _ level: Int) {
        guard depth[process.pid] == nil else { return }
        depth[process.pid] = level
        ordered.append(process)
        for child in children[process.pid] ?? [] { visit(child, level + 1) }
    }
    roots.forEach { visit($0, 0) }
    processes = ordered
    return depth
}
