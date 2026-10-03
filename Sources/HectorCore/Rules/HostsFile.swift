import Foundation

/// Reads and rewrites the Netbite section of `/etc/hosts`, leaving every other line untouched.
///
/// The section holds the personal domains first, then, after `listsMarker`, the domains of the
/// subscribed hosts lists. One section keeps flush and uninstall unchanged; the comment line keeps
/// the two parts apart for whoever reads the file.
public enum HostsFile {
    public static let beginMarker = "# >>> netbite managed block: do not edit >>>"
    public static let endMarker = "# <<< netbite managed block <<<"
    public static let listsMarker = "# hosts lists"

    /// `existing` with the Netbite section replaced by `domains` then `listDomains` (removed when
    /// both are empty). `listDomains` is expected sorted and without the personal domains.
    public static func render(existing: String, domains: [String], listDomains: [String] = []) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: beginMarker),
           let end = lines[begin...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...end)
        }
        while lines.last == "" { lines.removeLast() }

        if !domains.isEmpty || !listDomains.isEmpty {
            if lines.last.map({ !$0.isEmpty }) ?? false { lines.append("") }
            lines.reserveCapacity(lines.count + 2 * (domains.count + listDomains.count) + 3)
            lines.append(beginMarker)
            for domain in domains.sorted() {
                lines.append("0.0.0.0 \(domain)")
                lines.append(":: \(domain)")
            }
            if !listDomains.isEmpty {
                lines.append(listsMarker)
                for domain in listDomains {
                    lines.append("0.0.0.0 \(domain)")
                    lines.append(":: \(domain)")
                }
            }
            lines.append(endMarker)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Host names currently in the Netbite section, lists included.
    public static func managedDomains(in contents: String) -> [String] {
        let lines = contents.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker) else { return [] }
        let hosts = lines[(begin + 1)..<end].compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            return line.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
        return Array(Set(hosts)).sorted()
    }
}
