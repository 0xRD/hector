import CryptoKit
import Foundation

/// Pure readers for the files the root-only persistence sources look at: authorized SSH keys,
/// shell startup files, sudoers, PAM services, `at` jobs. They take bytes and return facts.
///
/// Some of these files hold secrets (a token exported in a `.zshrc`) or security policy (which
/// commands need no password). The readers that the helper runs on other people's files therefore
/// return facts and red flags, never the text.
extension PersistenceParsers {
    /// Text read from a file someone else wrote, made safe to show: no control characters (a
    /// terminal would obey them), bounded length.
    public static func displayable(_ text: String, maximumLength: Int = 1_000) -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= maximumLength {
                result.append("…")
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: result.append(" ")
            default: result.append(scalar)
            }
            count += 1
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - authorized_keys

    public struct AuthorizedKey: Equatable, Sendable {
        public var type: String
        /// `SHA256:…`, as `ssh-keygen -lf` prints it.
        public var fingerprint: String
        public var comment: String
        /// Option names only (`command`, `from`, `no-pty`…), in file order.
        public var options: [String]
        /// The value of `command="…"`: what runs instead of the user's shell.
        public var forcedCommand: String?
    }

    static let maximumAuthorizedKeys = 200

    /// Parses an `authorized_keys` file. `invalid` counts the lines that are neither a key nor a
    /// comment; at most `maximumAuthorizedKeys` keys are returned.
    public static func authorizedKeys(_ data: Data) -> (keys: [AuthorizedKey], invalid: Int) {
        var keys: [AuthorizedKey] = []
        var invalid = 0
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard keys.count < maximumAuthorizedKeys else { break }
            if let key = authorizedKey(line) { keys.append(key) } else { invalid += 1 }
        }
        return (keys, invalid)
    }

    private static func authorizedKey(_ line: String) -> AuthorizedKey? {
        let fields = quotedFields(line)
        guard let typeIndex = fields.prefix(2).firstIndex(where: isKeyType), fields.count > typeIndex + 1,
              let blob = Data(base64Encoded: fields[typeIndex + 1]), blob.count >= 16 else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        var key = AuthorizedKey(type: fields[typeIndex], fingerprint: "SHA256:" + digest,
                                comment: displayable(fields[(typeIndex + 2)...].joined(separator: " "), maximumLength: 200),
                                options: [])
        if typeIndex == 1 {
            for option in splitOutsideQuotes(fields[0], separator: ",") {
                let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                key.options.append(displayable(name.lowercased(), maximumLength: 40))
                if name.lowercased() == "command", parts.count == 2 {
                    var command = Substring(parts[1])
                    if command.count >= 2, command.hasPrefix("\""), command.hasSuffix("\"") { command = command.dropFirst().dropLast() }
                    key.forcedCommand = displayable(String(command))
                }
            }
        }
        return key
    }

    /// A known key type, made of the characters key types are made of: the field is shown as
    /// it is, and anything else (an escape sequence after a valid prefix) is not a key.
    private static func isKeyType(_ field: String) -> Bool {
        guard field.utf8.count <= 64, field.utf8.allSatisfy({ byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "@") || byte == UInt8(ascii: ".")
        }) else { return false }
        let known = ["ssh-rsa", "ssh-dss", "ssh-ed25519", "ecdsa-sha2-", "sk-ssh-ed25519@", "sk-ecdsa-sha2-",
                     "ssh-rsa-cert-", "ssh-ed25519-cert-", "ssh-dss-cert-"]
        return known.contains { field == $0 || ($0.hasSuffix("-") || $0.hasSuffix("@")) && field.hasPrefix($0) }
    }

    /// Splits on whitespace, keeping `"quoted text"` (with `\"` inside) in one field.
    private static func quotedFields(_ line: String) -> [String] {
        splitOutsideQuotes(line, separator: nil)
    }

    /// Splits on `separator` (whitespace when `nil`) wherever it is not inside double quotes.
    private static func splitOutsideQuotes(_ text: String, separator: Character?) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if !quoted, separator.map({ $0 == character }) ?? character.isWhitespace {
                if !current.isEmpty { fields.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { fields.append(current) }
        return fields
    }

    // MARK: - Shell startup files

    private static let shellFlags: [(note: String, pattern: NSRegularExpression)] = {
        let shells = #"(?:sudo\s+)?(?:/\S*/)?(?:ba|z|da|k|fi)?sh\b|python3?\b|perl\b|ruby\b|osascript\b|node\b"#
        let table: [(String, String)] = [
            ("downloads and runs code",
             #"\b(?:curl|wget)\b[^#]*(?:\|\s*(?:\#(shells))|\beval\b)|\b(?:eval|source|\.|(?:ba|z)?sh\s+-c)\s*[^#]*[`(]\s*(?:curl|wget)\b"#),
            ("decodes base64 text", #"\bbase64\s+(?:-d|-D|--decode)\b|\bopenssl\s+(?:enc|base64)\b[^#]*\s-d\b"#),
            ("opens a network connection", #"/dev/(?:tcp|udp)/|\b(?:nc|ncat|netcat|socat)\s+\S"#),
            ("sets a DYLD variable, which loads a library into programs", #"\b(?:DYLD_[A-Z_]+|LD_PRELOAD)\s*="#),
            ("redefines sudo, su or ssh", #"^\s*(?:alias\s+(?:-\w+\s+)*(?:sudo|su|ssh)=|function\s+(?:sudo|su|ssh)\b|(?:sudo|su|ssh)\s*\(\s*\))"#),
            ("runs an inline script", #"\b(?:python3?|perl|ruby|osascript|php|node)\s+(?:-\w+\s+)*-[ce]\b"#),
            ("starts a background job", #"\b(?:nohup|disown)\b|[^&|]&\s*$"#),
        ]
        return table.compactMap { note, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (note, $0) }
        }
    }()

    /// Red flags in a shell startup file (`.zshrc`, `/etc/profile`…): what malware adds to one.
    /// Only the names of the flags leave this function, never a line of the file.
    public static func shellStartupNotes(_ data: Data) -> [String] {
        var found = Set<Int>()
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // The beginning of a line is enough to tell, and bounds what a file written to be
            // slow to match can cost.
            let text = String(line.prefix(1_000))
            let range = NSRange(text.startIndex..., in: text)
            for (index, flag) in shellFlags.enumerated() where !found.contains(index) {
                if flag.pattern.firstMatch(in: text, range: range) != nil { found.insert(index) }
            }
            if found.count == shellFlags.count { break }
        }
        return found.sorted().map { shellFlags[$0].note }
    }

    // MARK: - sudoers

    public struct SudoersFacts: Equatable, Sendable {
        /// User specifications: lines that grant something.
        public var ruleCount = 0
        public var notes: [String] = []
        /// Exactly the two rules macOS ships (`root` and `%admin` may run anything, with a password).
        public var isStock = false
    }

    /// What a sudoers file allows, without its text: the helper runs this on files only root may
    /// read, and which commands need no password is not for every administrator process to know.
    public static func sudoers(_ data: Data, allowedIncludePrefixes: [String] = ["/private/etc/sudoers.d", "/etc/sudoers.d"]) -> SudoersFacts {
        var facts = SudoersFacts()
        var notes: [String] = []
        func note(_ text: String) { if !notes.contains(text) { notes.append(text) } }
        var rules: [String] = []

        // A trailing backslash continues the line.
        let joined = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\\n", with: " ")
        for rawLine in joined.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let first = words[0]
            if first.hasPrefix("#include") || first.hasPrefix("@include") {
                let target = words.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                // Compared as written, so anything that could lead elsewhere counts as elsewhere:
                // a relative path, a ".." component, or a % escape (sudo expands %h and others).
                let plain = target.hasPrefix("/") && !target.contains("%") && !target.split(separator: "/").contains("..")
                if !plain || !allowedIncludePrefixes.contains(where: { target == $0 || target.hasPrefix($0 + "/") }) {
                    note("includes rules from outside /etc/sudoers.d")
                }
                continue
            }
            if first.hasPrefix("#") { continue }
            if first.hasPrefix("Defaults") {
                let settings = line.dropFirst(first.count)
                if settings.contains("!authenticate") { note("turns off the password (!authenticate)") }
                if settings.contains("!env_reset") || settings.contains("setenv") { note("lets callers keep their environment") }
                if settings.contains("env_keep"), settings.contains("DYLD_") || settings.contains("LD_PRELOAD") || settings.contains("LD_LIBRARY") {
                    note("keeps library-loading variables (env_keep)")
                }
                if settings.range(of: #"timestamp_timeout\s*=\s*-"#, options: .regularExpression) != nil {
                    note("never asks for the password again (timestamp_timeout)")
                }
                continue
            }
            if ["User_Alias", "Runas_Alias", "Host_Alias", "Cmnd_Alias", "Cmd_Alias"].contains(first) { continue }
            facts.ruleCount += 1
            rules.append(words.joined(separator: " ").replacingOccurrences(of: " = ", with: "=").replacingOccurrences(of: " ", with: ""))
            if line.contains("NOPASSWD") { note("grants commands without a password (NOPASSWD)") }
            if line.contains("SETENV") { note("lets callers keep their environment") }
        }
        facts.notes = notes
        facts.isStock = notes.isEmpty && Set(rules) == ["rootALL=(ALL)ALL", "%adminALL=(ALL)ALL"] && rules.count == 2
        return facts
    }

    // MARK: - PAM

    public struct PAMEntry: Equatable, Sendable {
        /// auth, account, session or password.
        public var facility: String
        public var control: String
        /// A module (`pam_tid.so`, `/usr/local/lib/pam/x.so`), or the service an `include` names.
        public var module: String
    }

    /// Parses a file of `/etc/pam.d`: `facility control module [arguments]`.
    public static func pamService(_ data: Data) -> [PAMEntry] {
        var entries: [PAMEntry] = []
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 3 else { continue }
            let facility = words.removeFirst().lowercased()
            var control = words.removeFirst()
            // `[success=1 default=ignore]` is one control.
            if control.hasPrefix("["), !control.hasSuffix("]") {
                while let next = words.first {
                    control += " " + words.removeFirst()
                    if next.hasSuffix("]") { break }
                }
            }
            guard let module = words.first else { continue }
            entries.append(PAMEntry(facility: facility, control: control, module: displayable(module, maximumLength: 300)))
        }
        return entries
    }

    // MARK: - at

    public struct AtJob: Equatable, Sendable {
        public var queue: String
        public var number: Int
        public var runsAt: Date
    }

    /// The name of a file in the `at` spool says everything but the command: one letter for the
    /// queue (`=` while it runs), five hexadecimal digits of job number, eight of minutes since 1970.
    public static func atJob(named name: String) -> AtJob? {
        guard name.utf8.count == 14, let queue = name.first, queue.isLetter && queue.isASCII || queue == "=",
              let number = Int(name.dropFirst().prefix(5), radix: 16), let minutes = Int(name.suffix(8), radix: 16) else { return nil }
        return AtJob(queue: String(queue), number: number, runsAt: Date(timeIntervalSince1970: TimeInterval(minutes) * 60))
    }

    // MARK: - launchd environment

    /// The `DYLD_*` (and `LD_PRELOAD`) entries of a launchd job's `EnvironmentVariables`, as
    /// `NAME=value`, sorted: with them a job that runs a trusted program loads someone's library.
    public static func libraryInjection(environment: Any?) -> [String] {
        guard let variables = environment as? [String: Any] else { return [] }
        return variables.keys.sorted().filter { $0.hasPrefix("DYLD_") || $0 == "LD_PRELOAD" }.map { name in
            "\(displayable(name, maximumLength: 60))=\(displayable(variables[name] as? String ?? "", maximumLength: 300))"
        }
    }
}
