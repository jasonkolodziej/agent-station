import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fan-out for the UDS "subscribe channel (server-push)" in ARCHITECTURE.md
/// §2 — every canonical event the pipeline produces is broadcast, newline-
/// delimited JSON, to every connected subscriber fd (station CLI, menu bar,
/// notch app, VS Code extension bridge).
///
/// Lock-protected, not an actor: `publish` does blocking `write(2)` calls, and
/// blocking inside an actor ties up a thread from Swift's cooperative pool.
/// This mirrors `UnixSocketServer`'s own choice to keep raw POSIX I/O off of
/// Swift concurrency's executors entirely.
public final class SubscriberHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriberFDs: Set<Int32> = []

    public init() {}

    public func add(fd: Int32) {
        lock.lock()
        subscriberFDs.insert(fd)
        lock.unlock()
    }

    public func remove(fd: Int32) {
        lock.lock()
        subscriberFDs.remove(fd)
        lock.unlock()
    }

    /// Best-effort broadcast. A subscriber that can't keep up or has gone
    /// away is dropped silently — a slow CLI reader must never back-pressure
    /// the ingestion pipeline.
    public func publish(_ event: CanonicalEvent) {
        guard let data = try? Self.encoder.encode(event) else { return }
        var line = data
        line.append(0x0A)

        lock.lock()
        let fds = subscriberFDs
        lock.unlock()

        var dead: [Int32] = []
        for fd in fds {
            let ok = line.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok { dead.append(fd) }
        }
        guard !dead.isEmpty else { return }
        lock.lock()
        for fd in dead { subscriberFDs.remove(fd) }
        lock.unlock()
        for fd in dead { close(fd) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
