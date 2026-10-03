import Darwin
import Foundation
import HectorCore

/// `hector processes [--json] [--flagged] [--tree] [--socket PATH]`
func processes(_ args: Arguments) throws {
    let socket = args.options["--socket"] ?? HelperPaths.socket
    var snapshot = ProcessCollector().snapshot()
    var throughHelper = false
    if geteuid() != 0, FileManager.default.fileExists(atPath: socket),
       case .processes(let fromHelper)? = try? HelperClient.sendChecked(.processes, socketPath: socket, timeout: 10) {
        snapshot = fromHelper
        throughHelper = true
    }

    let flags = Dictionary(uniqueKeysWithValues: snapshot.processes.map {
        ($0.pid, ProcessFlag.flags(forExecutable: $0.executablePath))
    })
    var shown = snapshot.processes
    if args.flags.contains("--flagged") { shown = shown.filter { !(flags[$0.pid] ?? []).isEmpty } }

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.hector.encode(shown), as: UTF8.self))
        return
    }

    var depth: [Int32: Int] = [:]
    if args.flags.contains("--tree") && !args.flags.contains("--flagged") {
        let tree = snapshot.treeOrdered()
        shown = tree.map { $0.process }
        depth = Dictionary(uniqueKeysWithValues: tree.map { ($0.process.pid, $0.depth) })
    }
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
