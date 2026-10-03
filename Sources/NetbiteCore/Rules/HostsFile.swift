import Foundation

/// Reads and rewrites the Netbite section of `/etc/hosts`, leaving every other line untouched.
public enum HostsFile {
    public static let beginMarker = "# >>> netbite managed block: do not edit >>>"
    public static let endMarker = "# <<< netbite managed block <<<"

    /// `existing` with the Netbite section replaced by `domains` (removed when `domains` is empty).
    public static func render(existing: String, domains: [String]) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: beginMarker),
           let end = lines[begin...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...end)
        }
        while lines.last == "" { lines.removeLast() }

        if !domains.isEmpty {
            if lines.last.map({ !$0.isEmpty }) ?? false { lines.append("") }
            lines.append(beginMarker)
            for domain in domains.sorted() {
                lines.append("0.0.0.0 \(domain)")
                lines.append(":: \(domain)")
            }
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Host names currently in the Netbite section.
    public static func managedDomains(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker) else { return [] }
        let hosts = lines[(begin + 1)..<end].compactMap { line in
            line.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
        return Array(Set(hosts)).sorted()
    }
}
