import Darwin
import Foundation
import HectorCore

// `hector sign` and `hector vt`: code signature analysis and VirusTotal hash lookups.

func security(_ command: String, _ args: Arguments) async throws {
    switch command {
    case "sign": try signCommand(args)
    default: try await virusTotalCommand(args)
    }
}

// MARK: - sign

private struct SignEntry: Encodable {
    let path: String
    let signature: CodeSignatureInfo?
    let sha256: String?
    let error: String?
}

func signCommand(_ args: Arguments) throws {
    guard !args.positional.isEmpty else { throw CLIError("Give at least one file or app bundle, e.g. `hector sign /bin/ls`.") }
    var entries: [SignEntry] = []
    for path in args.positional {
        let url = URL(fileURLWithPath: path)
        do {
            let signature = try CodeSignature.analyze(url)
            let sha256 = try? FileHash.sha256(of: FileHash.hashTarget(for: url, signature: signature))
            entries.append(SignEntry(path: path, signature: signature, sha256: sha256, error: nil))
        } catch {
            entries.append(SignEntry(path: path, signature: nil, sha256: nil, error: "\(error)"))
        }
    }

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.hector.encode(entries), as: UTF8.self))
    } else {
        for entry in entries {
            print(entry.path)
            guard let s = entry.signature else {
                print("  error: \(entry.error ?? "unknown")\n")
                continue
            }
            row("Trust", s.trustLevel.label)
            if let problem = s.validationError { row("Problem", problem) }
            if let signer = s.signerName { row("Signer", signer) }
            if s.isSigned {
                row("Team ID", s.teamIdentifier ?? "-")
                row("Identifier", s.signingIdentifier ?? "-")
                row("Notarized", s.isNotarized ? "yes" : (s.isApplePlatform || s.isAppStore ? "n/a" : "no"))
                row("Hardened runtime", s.hasHardenedRuntime ? "yes" : "no")
                row("Entitlements", s.entitlementCount.map(String.init) ?? "none")
            }
            if let executable = s.mainExecutable, executable != entry.path { row("Executable", executable) }
            row("SHA-256", entry.sha256 ?? "-")
            print("")
        }
    }
    try failIfAny(entries.filter { $0.error != nil }.count, of: entries.count)
}

// MARK: - vt

private struct VTEntry: Encodable {
    let path: String
    let sha256: String?
    let lookup: VirusTotalLookup?
    let error: String?
}

func virusTotalCommand(_ args: Arguments) async throws {
    let store = APIKeyStore()
    if args.positional.first == "key" {
        switch args.positional.dropFirst().first {
        case "set":
            guard args.positional.count == 2 else {
                throw CLIError("Pass the key on stdin, not as an argument, so it stays out of shell history:\n  pbpaste | hector vt key set")
            }
            guard let key = readSecret(prompt: "VirusTotal API key: ") else { throw CLIError("No key read from stdin.") }
            try store.save(key)
            print("Saved the VirusTotal API key in the login Keychain (service \(store.service)).")
        case "delete":
            print(try store.delete() ? "Deleted the VirusTotal API key." : "No VirusTotal API key was stored.")
        default:
            throw CLIError("Use `hector vt key set` or `hector vt key delete`.")
        }
        return
    }

    guard !args.positional.isEmpty else { throw CLIError("Give at least one file or app bundle, e.g. `hector vt /Applications/Foo.app`.") }
    guard let key = try store.read() else {
        throw CLIError("No VirusTotal API key. Get a free one at https://www.virustotal.com/gui/my-apikey, then: pbpaste | hector vt key set")
    }
    let limiter = VirusTotalClient.defaultRateLimiter(onWait: { seconds in
        FileHandle.standardError.write(Data("Waiting \(Int(seconds.rounded(.up))) s for the VirusTotal free tier limit (4 lookups per minute)…\n".utf8))
    })
    let client = try VirusTotalClient(apiKey: key, rateLimiter: limiter)
    let refresh = args.flags.contains("--refresh")

    var entries: [VTEntry] = []
    for path in args.positional {
        let url = URL(fileURLWithPath: path)
        let sha256: String
        do {
            sha256 = try FileHash.sha256(of: FileHash.hashTarget(for: url, signature: nil))
        } catch {
            entries.append(VTEntry(path: path, sha256: nil, lookup: nil, error: "\(error)"))
            continue
        }
        do {
            let lookup = try await client.lookup(sha256: sha256, refresh: refresh)
            entries.append(VTEntry(path: path, sha256: sha256, lookup: lookup, error: nil))
        } catch let error as VirusTotalError {
            switch error {
            // Account-wide problems: every remaining lookup would fail the same way.
            case .invalidAPIKey, .rateLimited, .dailyQuotaExhausted: throw CLIError(error.description)
            default: entries.append(VTEntry(path: path, sha256: sha256, lookup: nil, error: error.description))
            }
        }
    }

    if args.flags.contains("--json") {
        print(String(decoding: try JSONEncoder.hector.encode(entries), as: UTF8.self))
    } else {
        let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
        for entry in entries {
            print(entry.path)
            if let sha256 = entry.sha256 { row("SHA-256", sha256) }
            if let error = entry.error { row("Error", error) }
            if let lookup = entry.lookup {
                if let report = lookup.report {
                    let stats = report.stats
                    var detections = "\(stats.malicious) / \(stats.verdictCount) malicious"
                    if stats.suspicious > 0 { detections += ", \(stats.suspicious) suspicious" }
                    row("Detections", detections)
                    if let label = report.threatLabel { row("Threat label", label) }
                    if let name = report.meaningfulName { row("Known as", name) }
                    if let analyzed = report.lastAnalysisDate { row("Last analysis", analyzed.formatted(date)) }
                } else {
                    row("VirusTotal", "unknown file (never submitted; Hector does not upload files)")
                }
                row("Report", lookup.permalink.absoluteString)
                if lookup.fromCache { row("Cached", lookup.fetchedAt.formatted(date) + " (--refresh to look up again)") }
            }
            print("")
        }
    }
    try failIfAny(entries.filter { $0.error != nil }.count, of: entries.count)
}

// MARK: - Helpers

/// The file to hash for a path: a bundle's main executable, otherwise the file itself.
/// Reads one line from stdin without echoing it when stdin is a terminal.
private func readSecret(prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1 else { return readLine(strippingNewline: true) }
    var buffer = [CChar](repeating: 0, count: 256)
    // memset_s cannot be optimized away: the key does not linger in this buffer.
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
}

private func row(_ label: String, _ value: String) {
    print("  " + pad(label, 18) + value)
}

private func failIfAny(_ failures: Int, of total: Int) throws {
    guard failures > 0 else { return }
    throw CLIError(failures == total ? "Nothing could be analyzed." : "\(failures) of \(total) paths could not be analyzed.")
}
