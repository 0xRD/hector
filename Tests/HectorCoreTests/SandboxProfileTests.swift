import Darwin
import Foundation
import Testing
@testable import HectorCore

/// The helper's sandbox profile (`HelperSandboxProfile`), checked as text and for real with
/// `sandbox-exec` on a dry-run profile.
@Suite struct SandboxProfileTests {
    @Test func systemProfileWritesOnlyHelperPaths() {
        let profile = HelperSandboxProfile.source(executable: HelperPaths.installedBinary, dryRunRoot: nil,
                                                  socketPath: HelperPaths.socket)
        #expect(profile.contains("(deny file-write*)"))
        #expect(profile.contains("(subpath \"/Library/Application Support/Hector\")"))
        #expect(profile.contains("(literal \"/private/etc/hosts\")"))
        #expect(profile.contains("(literal \"/private/var/run/io.github.0xrd.hectord.sock\")"))
        #expect(profile.contains("(literal \"/Library/PrivilegedHelperTools/io.github.0xrd.hectord\")"))
        #expect(!profile.contains("/Library/LaunchDaemons"))
        #expect(!profile.contains("(subpath \"/private/etc\")"))
        #expect(!profile.contains("/bin/sh"))
    }

    @Test func pathsCannotEscapeTheirString() {
        let hostile = "/tmp/x\") (allow file-write* (subpath \"/\")) (\"\\"
        let quoted = HelperSandboxProfile.quoted(hostile)
        #expect(quoted == "\"/tmp/x\\\") (allow file-write* (subpath \\\"/\\\")) (\\\"\\\\\"")
        let profile = HelperSandboxProfile.source(executable: "/bin/sh", dryRunRoot: hostile, socketPath: "/tmp/s")
        #expect(!profile.contains("(allow file-write* (subpath \"/\"))"))
    }

    @Test func realPathResolvesMissingLastComponent() {
        #expect(HelperSandboxProfile.realPath("/var/run/hector-missing.sock") == "/private/var/run/hector-missing.sock")
        #expect(HelperSandboxProfile.realPath("/etc/hosts") == "/private/etc/hosts")
    }

    /// zsh is the "helper" here (/bin/sh would start bash, which the profile refuses): its builtins may write inside the dry-run folder only, and
    /// it may not start another program.
    @Test func dryRunProfileIsEnforced() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hector-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appending(path: "hector-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let profile = HelperSandboxProfile.source(executable: "/bin/zsh", dryRunRoot: root.path,
                                                  socketPath: root.appending(path: "s.sock").path)
        let inside = root.appending(path: "inside")
        let script = "echo ok > '\(inside.path)'; echo no > '\(outside.path)'; /usr/bin/true && echo ran"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/zsh", "-f", "-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!printed.contains("ran"))
    }
}
