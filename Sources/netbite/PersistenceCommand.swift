import Darwin
import Foundation
import NetbiteCore

/// `netbite persistence [--json] [--include-apple] [--category NAME[,NAME…]]`
func persistence(_ args: Arguments) throws {
    var categories: Set<PersistenceItem.Category>?
    if let names = args.options["--category"] {
        categories = try Set(names.split(separator: ",").map { try category(named: String($0)) })
    }
    let report = PersistenceScanner().scan(options: .init(includeApple: args.flags.contains("--include-apple"),
                                                           categories: categories))

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.netbite.encode(report), as: UTF8.self))
        return
    }

    for category in PersistenceItem.Category.allCases {
        let items = report.items(in: category)
        guard !items.isEmpty else { continue }
        print("\(category.title) (\(items.count))")
        for item in items {
            print("  " + pad(item.scope.rawValue, 7) + pad(clipped(item.label, 43), 44) + " " + pad(flags(item), 18)
                  + (item.executablePath ?? item.configurationPath ?? ""))
            for note in item.notes { print("  " + String(repeating: " ", count: 7) + "! \(note)") }
        }
        print("")
    }

    let counts = PersistenceItem.Category.allCases.compactMap { category -> String? in
        let count = report.items(in: category).count
        return count > 0 ? "\(count) \(category.title.lowercased())" : nil
    }
    let flagged = report.items.filter { !$0.notes.isEmpty }.count
    print("\(report.items.count) items" + (counts.isEmpty ? "" : ": " + counts.joined(separator: ", ")) + ".")
    print("\(flagged) with notes. Scanned in \(String(format: "%.1f", report.duration)) s.")
    for source in report.sources {
        for note in source.notes { print("\(source.name): \(note)") }
    }
    if !args.flags.contains("--include-apple") {
        print("Apple's own items are hidden; add --include-apple to list them.")
    }
}

/// "launch-agents", "LaunchAgent" and "launchagent" all name `.launchAgent`.
private func category(named raw: String) throws -> PersistenceItem.Category {
    func normalized(_ s: String) -> String {
        var s = s.lowercased().filter { $0.isLetter }
        if s.hasSuffix("s") { s.removeLast() }
        return s
    }
    let wanted = normalized(raw)
    guard let match = PersistenceItem.Category.allCases.first(where: { normalized($0.rawValue) == wanted }) else {
        let names = PersistenceItem.Category.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError("Unknown category: \(raw). Use one of: \(names)")
    }
    return match
}

/// Long labels (cron commands, extension names) would push every other column out of line.
private func clipped(_ s: String, _ width: Int) -> String {
    s.count <= width ? s : String(s.prefix(width - 1)) + "…"
}

private func flags(_ item: PersistenceItem) -> String {
    var flags: [String] = []
    if item.runAtLoad == true { flags.append("load") }
    if item.keepAlive == true { flags.append("keepalive") }
    if item.isDisabled == true { flags.append("disabled") }
    if let version = item.version, flags.isEmpty { flags.append(version) }
    return flags.joined(separator: ",")
}
