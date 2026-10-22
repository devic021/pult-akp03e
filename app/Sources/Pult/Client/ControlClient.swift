import Foundation

/// Reads newline-delimited JSON from a socket in chunks.
///
/// One `read` per byte is one system call per byte. Measured against a 2.7 MB
/// reply — a thirty-three frame canvas preview — that is 1024 ms where reading
/// in 64 KB chunks takes 34: thirty times slower. It matters more than it
/// sounds, because the receive timeout below is five seconds, so a reply
/// carrying frames could time out *in the transfer itself* rather than
/// because the daemon was slow, and the interface would report a dock that is
/// working perfectly as broken.
///
/// Chunking also fixes what the timeout means. Five seconds is now five
/// seconds with no data at all, instead of five seconds for the whole reply.
private struct LineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []
    /// How far into `buffer` a newline has already been looked for, so a long
    /// reply is scanned once rather than once per chunk.
    private var scanned = 0

    init(_ fd: Int32) {
        self.fd = fd
    }

    /// The next line without its newline, or nil once the peer has closed.
    mutating func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let end = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<end])
                buffer.removeFirst(end + 1)
                scanned = 0
                return line
            }
            scanned = buffer.count

            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            guard n > 0 else {
                // A last line with no trailing newline is still a line; only
                // an empty buffer means there is nothing more coming.
                guard !buffer.isEmpty else { return nil }
                let line = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                scanned = 0
                return line
            }
            buffer.append(contentsOf: chunk[..<n])
        }
    }
}

/// Talks to the daemon over its Unix socket.
///
/// Every call opens a connection, asks one question and closes it. That costs
/// a few hundred microseconds and removes a whole class of problems: no shared
/// socket state, no half-read buffers, nothing to reconnect after the daemon
/// restarts. The event stream is the one long-lived connection.
struct ControlClient {
    enum Failure: LocalizedError {
        case unreachable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable: return T("status.disconnected")
            case .refused(let message): return message
            }
        }
    }

    static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/Pult/control.sock"
    }

    /// Sends one request and returns the parsed reply.
    @discardableResult
    func send(_ request: [String: Any]) throws -> [String: Any] {
        let fd = try connect()
        defer { close(fd) }

        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)

        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { throw Failure.unreachable }
                sent += n
            }
        }

        var reader = LineReader(fd)
        guard let line = reader.next() else { throw Failure.unreachable }

        guard
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { throw Failure.refused("malformed reply") }

        if object["ok"] as? Bool == false {
            throw Failure.refused(object["error"] as? String ?? "refused")
        }
        return object
    }

    /// Decodes a typed value out of one field of the reply.
    func send<T: Decodable>(_ request: [String: Any], as type: T.Type, field: String) throws -> T {
        let reply = try send(request)
        guard let value = reply[field] else {
            throw Failure.refused("reply has no \(field)")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes the whole reply as a typed value.
    func send<T: Decodable>(_ request: [String: Any], as type: T.Type) throws -> T {
        let reply = try send(request)
        let data = try JSONSerialization.data(withJSONObject: reply)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unreachable }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure.unreachable
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.utf8.count + 1) { destination in
                strcpy(destination, path)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.connect(fd, address, size)
            }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure.unreachable
        }

        // Without this a wedged daemon would hang the interface for good.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return fd
    }

    /// Opens the event stream. The closure runs on a background thread for
    /// every event until the daemon goes away.
    func subscribe(onEvent: @escaping ([String: Any]) -> Void, onClose: @escaping () -> Void) {
        Thread.detachNewThread {
            guard let fd = try? connect() else {
                onClose()
                return
            }
            defer { close(fd) }

            // The stream must not time out: quiet docks are normal.
            var forever = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))

            var payload = Data(#"{"cmd":"subscribe"}"#.utf8)
            payload.append(0x0A)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }

            var reader = LineReader(fd)
            while let line = reader.next() {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    onEvent(object)
                }
            }
            onClose()
        }
    }
}
