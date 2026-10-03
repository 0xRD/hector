import Foundation
import HectorCore

/// `hector checkup [--json]`
func checkup(_ args: Arguments) throws {
    let report = SecurityCheckup().run()

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.hector.encode(report), as: UTF8.self))
        return
    }

    print("Security checkup: \(report.summary).\n")
    let width = (report.results.map(\.title.count).max() ?? 0) + 2
    for result in report.results {
        print("  " + pad(label(result.status), 9) + pad(result.title, width) + result.finding)
        if result.status != .pass {
            print("  " + String(repeating: " ", count: 9 + width) + "Fix: \(result.howToFix)")
        }
    }

    var counts: [String] = []
    for status in [CheckResult.Status.fail, .warning, .unknown] {
        let count = report.count(status)
        if count > 0 { counts.append("\(count) \(label(status))" + (status == .warning && count > 1 ? "s" : "")) }
    }
    print("")
    if !counts.isEmpty { print(counts.joined(separator: ", ") + ".") }
    if report.results.contains(where: { $0.finding.contains("needs the helper") }) {
        print("Some settings can only be read by root; Hector never asks for a password to read them.")
    }
    print("Nothing was changed. Checked in \(String(format: "%.1f", report.duration)) s.")
}

private func label(_ status: CheckResult.Status) -> String {
    switch status {
    case .pass: "pass"
    case .warning: "warning"
    case .fail: "FAIL"
    case .unknown: "unknown"
    }
}
