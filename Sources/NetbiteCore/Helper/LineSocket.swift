import Darwin
import Foundation

/// Newline-delimited JSON over a Unix domain socket, shared by the helper and its clients.
public enum LineSocket {
    /// Requests and responses larger than this are refused (a full root snapshot is well below).
    public static let maximumMessageSize = 32 * 1024 * 1024

    public struct SocketError: Error, CustomStringConvertible {
        public let description: String
        init(_ what: String, errno code: Int32 = errno) {
            description = code == 0 ? what : "\(what): \(String(cString: strerror(code)))"
        }
    }

    /// A `sockaddr_un` for `path`; throws if the path does not fit (104 bytes on macOS).
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError("Socket path too long", errno: 0) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Connects to `path`, giving up on reads and writes after `timeout` seconds.
    public static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var address = try Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SocketError("Cannot reach the Netbite helper at \(path)")
            close(fd)
            throw error
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public static func write(_ data: Data, to fd: Int32) throws {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw SocketError("write") }
                offset += written
            }
        }
    }

    /// Reads until the first newline (excluded) or end of stream.
    ///
    /// `deadline` bounds the whole read, not each `read()`: a peer trickling one byte at a time
    /// would otherwise keep the connection, and a one-request-at-a-time server, busy forever.
    public static func readLine(from fd: Int32, maximumSize: Int = maximumMessageSize,
                                deadline: Date? = nil) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let deadline, Date() >= deadline { throw SocketError("Timed out reading the message", errno: 0) }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw SocketError("read") }
            if count == 0 { return data }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= maximumSize else { throw SocketError("Message too large", errno: 0) }
                return data
            }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= maximumSize else { throw SocketError("Message too large", errno: 0) }
        }
    }
}

/// Talks to the privileged helper. Calls block: use them off the main thread.
public enum HelperClient {
    public static func send(_ request: HelperRequest, socketPath: String = HelperPaths.socket,
                            timeout: TimeInterval = 120) throws -> HelperResponse {
        let fd = try LineSocket.connect(to: socketPath, timeout: timeout)
        defer { close(fd) }
        try LineSocket.write(JSONEncoder.netbiteWire.encode(request), to: fd)
        let reply = try LineSocket.readLine(from: fd)
        return try JSONDecoder.netbite.decode(HelperResponse.self, from: reply)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperPaths.socket)
    }
}
