import Darwin
import Foundation

/// Reads files that someone else controls, for a process that may be root.
///
/// A scan that runs as root looks into folders any user can fill: home folders above all. Whoever
/// owns such a folder can put anything where the scan looks: a symbolic link to a file only root
/// may read, a named pipe that never answers, a file of 10 GB. So:
///
/// - a path is walked one component at a time from a directory the caller trusts, and no
///   component may be a symbolic link (`O_NOFOLLOW` at every step, not only the last one);
/// - only regular files are read, and opening never blocks (`O_NONBLOCK`);
/// - a read stops at the size the caller gives, and a listing at a number of entries;
/// - names come from the code, never from a client, and are single components.
///
/// Everything goes through file descriptors (`openat`, `fstat`), so what was checked is what is
/// read: there is no path to swap between the check and the read.
public final class GuardedDirectory: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let code: Int32

        public var isMissing: Bool { code == ENOENT || code == ENOTDIR }
        public var description: String {
            switch code {
            case ELOOP: "\(path) is a symbolic link"
            case EPERM: "macOS refused to read \(path) (Operation not permitted)"
            case EFTYPE: "\(path) is not a regular file"
            default: "\(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public enum Kind: Sendable { case regular, directory, symbolicLink, other }

    /// What `fstat` says, taken from the open file itself.
    public struct Facts: Sendable {
        public var kind: Kind
        public var owner: uid_t
        /// Permission bits only.
        public var permissions: Int
        public var size: Int
        public var modified: Date
        public var linkCount: Int

        init(_ info: stat) {
            kind = switch info.st_mode & S_IFMT {
            case S_IFREG: .regular
            case S_IFDIR: .directory
            case S_IFLNK: .symbolicLink
            default: .other
            }
            owner = info.st_uid
            permissions = Int(info.st_mode & 0o7777)
            size = Int(info.st_size)
            modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            linkCount = Int(info.st_nlink)
        }

        /// Someone other than the owner may change the file.
        public var isWritableByOthers: Bool { permissions & 0o022 != 0 }
    }

    public struct Contents: Sendable {
        public var facts: Facts
        public var data: Data
        /// The file is larger than the limit; `data` is its beginning.
        public var truncated: Bool
    }

    public let path: String
    private let descriptor: Int32

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit { close(descriptor) }

    /// Opens a directory the caller trusts: symbolic links in `path` are followed.
    public init(trusted path: String) throws(Failure) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(path: path, code: errno) }
        descriptor = fd
        self.path = path
    }

    /// The directory `name` inside this one. Refuses a symbolic link.
    public func directory(_ name: String) throws(Failure) -> GuardedDirectory {
        let child = childPath(name)
        guard Self.isSingleComponent(name) else { throw Failure(path: child, code: EINVAL) }
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            // macOS answers "not a directory" for a link; say what it is, so it is not taken for
            // a folder that is simply absent.
            let code = errno
            throw Failure(path: child, code: code == ENOTDIR && facts(of: name)?.kind == .symbolicLink ? ELOOP : code)
        }
        return GuardedDirectory(descriptor: fd, path: child)
    }

    /// Walks `components` down from this directory, refusing a symbolic link at every step.
    public func descend(_ components: [String]) throws(Failure) -> GuardedDirectory {
        var current = self
        for component in components { current = try current.directory(component) }
        return current
    }

    /// `relativePath` split on "/" and walked with `descend`.
    public func descend(_ relativePath: String) throws(Failure) -> GuardedDirectory {
        try descend(relativePath.split(separator: "/").map(String.init))
    }

    public var facts: Facts? {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? Facts(info) : nil
    }

    /// Facts about `name` without opening it; a symbolic link is described, not followed.
    public func facts(of name: String) -> Facts? {
        guard Self.isSingleComponent(name) else { return nil }
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? Facts(info) : nil
    }

    /// The names in this directory, sorted, without "." and "..". At most `limit` are read;
    /// `complete` is false when there were more.
    public func names(limit: Int = 1_024) throws(Failure) -> (names: [String], complete: Bool) {
        // fdopendir takes over its descriptor: give it a copy.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Failure(path: path, code: errno) }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw Failure(path: path, code: code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        var complete = true
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if names.count >= limit {
                complete = false
                break
            }
            names.append(name)
        }
        return (names.sorted(), complete)
    }

    /// The beginning of the regular file `name`, at most `maximumSize` bytes. Throws for a
    /// missing file, a symbolic link, a pipe, a device or a directory.
    public func read(_ name: String, maximumSize: Int) throws(Failure) -> Contents {
        let child = childPath(name)
        guard Self.isSingleComponent(name) else { throw Failure(path: child, code: EINVAL) }
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(path: child, code: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure(path: child, code: errno) }
        let facts = Facts(info)
        guard facts.kind == .regular else { throw Failure(path: child, code: EFTYPE) }

        let wanted = max(0, min(facts.size, maximumSize))
        var data = Data(count: wanted)
        let count = data.withUnsafeMutableBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let got = Darwin.read(fd, raw.baseAddress! + offset, raw.count - offset)
                if got <= 0 { break }
                offset += got
            }
            return offset
        }
        data.count = count
        return Contents(facts: facts, data: data, truncated: facts.size > maximumSize)
    }

    private func childPath(_ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
