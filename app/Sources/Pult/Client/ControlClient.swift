import Foundation

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

        var line = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            line.append(byte)
        }

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

            var line = Data()
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 {
                if byte != 0x0A {
                    line.append(byte)
                    continue
                }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    onEvent(object)
                }
                line.removeAll(keepingCapacity: true)
            }
            onClose()
        }
    }
}
