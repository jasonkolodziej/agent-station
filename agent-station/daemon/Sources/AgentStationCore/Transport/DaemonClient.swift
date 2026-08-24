import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin UDS client for the daemon's subscribe channel. Shared by every
/// Swift-side consumer — station CLI today, menu bar and notch app later
/// (ARCHITECTURE.md §2). The TypeScript equivalent for the VS Code extension
/// is `extension/src/daemonClient.ts`; keep the wire protocol identical.
public enum DaemonClient {
    public enum ClientError: Error, Sendable {
        case socketCreationFailed(errno: Int32)
        case pathTooLong
        case connectFailed(errno: Int32)
    }

    /// Connects, subscribes, and streams decoded canonical events to `onEvent`
    /// as they arrive. Blocking — call from a background thread/Task, never
    /// from inside an actor's synchronous body.
    public static func tail(
        socketPath: URL = UnixSocketServer.defaultPath,
        onEvent: @escaping (CanonicalEvent) -> Void,
        onDisconnect: @escaping () -> Void = {}
    ) throws {
        let fd = try openConnection(to: socketPath)
        defer { close(fd) }

        let request = Data(#"{"op":"subscribe"}"#.utf8) + Data([0x0A])
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { onDisconnect(); return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard !line.isEmpty, let event = try? decoder.decode(CanonicalEvent.self, from: line) else { continue }
                onEvent(event)
            }
        }
    }

    /// True if the daemon's socket file exists — the same fail-open check the
    /// shim itself makes before attempting to connect.
    public static func isDaemonReachable(socketPath: URL = UnixSocketServer.defaultPath) -> Bool {
        FileManager.default.fileExists(atPath: socketPath.path)
    }

    private static func openConnection(to path: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketCreationFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw ClientError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw ClientError.connectFailed(errno: err)
        }
        return fd
    }
}
