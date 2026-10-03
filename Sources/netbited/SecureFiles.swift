import Darwin
import Foundation

/// File operations for a process running as root in directories it does not fully control.
///
/// Every check uses `lstat`, so a symlink planted where Netbite expects a file or a directory is
/// refused instead of followed, and everything Netbite writes is owned by root and not writable by
/// anyone else.
enum SecureFiles {
    struct InsecurePath: Error, CustomStringConvertible {
        let description: String
    }

    /// Creates `path` as a root-owned directory with `mode`, or checks that the existing one is a
    /// real directory, owned by root, and writable by root only.
    static func ensureDirectory(_ path: String, mode: mode_t) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw InsecurePath(description: "Cannot inspect \(path).") }
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, parent != "/" { try ensureParentIsSafe(parent) }
            guard mkdir(path, mode) == 0 || errno == EEXIST else { throw InsecurePath(description: "Cannot create \(path).") }
            guard lstat(path, &info) == 0 else { throw InsecurePath(description: "Cannot inspect \(path).") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw InsecurePath(description: "\(path) is not a directory (symlink?).") }
        guard info.st_uid == 0 || geteuid() != 0 else { throw InsecurePath(description: "\(path) is not owned by root.") }
        if info.st_mode & 0o022 != 0 {
            guard chmod(path, mode) == 0 else { throw InsecurePath(description: "\(path) is writable by others.") }
        }
    }

    /// System parents such as /Library/Application Support may belong to the admin group, but must
    /// be real directories owned by root.
    private static func ensureParentIsSafe(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || geteuid() != 0 else {
            throw InsecurePath(description: "\(path) is not a root-owned directory.")
        }
    }

    /// Creates an empty root-owned file, replacing whatever was at `path` (a symlink included).
    static func createFile(_ path: String, mode: mode_t) throws {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFREG || info.st_uid != 0 {
            unlink(path)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw InsecurePath(description: "Cannot create \(path).") }
        defer { close(fd) }
        guard fchown(fd, 0, 0) == 0 || geteuid() != 0, fchmod(fd, mode) == 0 else {
            throw InsecurePath(description: "Cannot secure \(path).")
        }
    }

    /// Writes `data` to a temporary file in the same directory, then renames it over `path`.
    /// `rename` replaces a symlink instead of following it.
    static func write(_ data: Data, to path: String, mode: mode_t) throws {
        let temporary = path + ".netbite-\(UUID().uuidString)"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw InsecurePath(description: "Cannot write \(path).") }
        var ok = data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        ok = ok && fchmod(fd, mode) == 0 && fsync(fd) == 0
        if geteuid() == 0 { ok = ok && fchown(fd, 0, 0) == 0 }
        close(fd)
        guard ok, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw InsecurePath(description: "Cannot write \(path).")
        }
    }
}
