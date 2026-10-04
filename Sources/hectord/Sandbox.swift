import Darwin
import Foundation
import HectorCore

/// Applies `HelperSandboxProfile` to `hectord serve`, for good: a sandboxed process cannot leave
/// its sandbox.
enum HelperSandbox {
    /// Set once by `serve`, before the first connection; read by `hello`.
    nonisolated(unsafe) static var isApplied = false

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func profile(dryRunRoot: URL?, socketPath: String) -> String {
        HelperSandboxProfile.source(executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                                    dryRunRoot: dryRunRoot?.path, socketPath: socketPath)
    }

    static func apply(dryRunRoot: URL?, socketPath: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sandbox_init(profile(dryRunRoot: dryRunRoot, socketPath: socketPath), 0, &error) == 0 else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            if let error { sandbox_free_error(error) }
            throw Failure(description: "Cannot apply the sandbox: \(message)")
        }
        isApplied = true
    }
}

// libsystem_sandbox. Marked deprecated in <sandbox.h> since 10.8, but still exported and working;
// the Darwin module does not bring it to Swift. No entitlement or Developer ID is needed.
@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                          _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_silgen_name("sandbox_free_error")
private func sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>)
