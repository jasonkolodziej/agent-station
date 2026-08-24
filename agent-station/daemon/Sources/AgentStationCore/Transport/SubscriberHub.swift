import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fan-out for the UDS "subscribe channel (server-push)" in ARCHITECTURE.md
/// §2 — every canonical event the pipeline produces is broadcast, newline-
/// delimited JSON, to every connected subscriber fd (station CLI, menu bar,
/// notch app, VS Code extension bridge).
///
/// Two subscription modes, matching `station tail` vs `station tail --raw`:
/// - canonical (default): the mapped `CanonicalEvent`.
/// - raw: the verbatim provider payload, pre-normalization. This is the
///   `station tail --raw` capture path fixtures/README.md documents as how
///   golden fixtures get built — "Capture real payloads, don't hand-write
///   them" — so it has to carry what the provider actually sent, not a
///   re-description of what the mapping produced from it.
///
/// Lock-protected, not an actor: `publish`/`publishRaw` do blocking `write(2)`
/// calls, and blocking inside an actor ties up a thread from Swift's
/// cooperative pool. This mirrors `UnixSocketServer`'s own choice to keep raw
/// POSIX I/O off of Swift concurrency's executors entirely.
public final class SubscriberHub: @unchecked Sendable {
    private let lock = NSLock()
    /// fd -> wants raw payloads instead of canonical events.
    private var subscribers: [Int32: Bool] = [:]

    public init() {}

    public func add(fd: Int32, raw: Bool) {
        lock.lock()
        subscribers[fd] = raw
        lock.unlock()
    }

    public func remove(fd: Int32) {
        lock.lock()
        subscribers[fd] = nil
        lock.unlock()
    }

    /// Best-effort broadcast to canonical-mode subscribers. A subscriber that
    /// can't keep up or has gone away is dropped silently — a slow CLI reader
    /// must never back-pressure the ingestion pipeline.
    public func publish(_ event: CanonicalEvent) {
        guard let data = try? Self.encoder.encode(event) else { return }
        broadcast(data, toRaw: false)
    }

    /// Best-effort broadcast to raw-mode subscribers. Re-serializes the
    /// already-parsed payload (parseEnvelope round-tripped it through
    /// JSONSerialization), so this isn't guaranteed byte-identical to what the
    /// provider sent — key order and whitespace can differ — but it's
    /// semantically the same payload, which is what a fixture capture needs.
    public func publishRaw(_ raw: RawEvent) {
        var dict: [String: Any] = [
            "provider": raw.provider.rawValue,
            "received_at": ISO8601DateFormatter().string(from: raw.receivedAt),
            "truncated": raw.truncated,
        ]
        dict["raw"] = (try? JSONSerialization.jsonObject(with: raw.raw)) ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        broadcast(data, toRaw: true)
    }

    /// The VS Code status bar's live counts (ARCHITECTURE.md §7.2,
    /// `extension.ts`'s `msg['event'] === 'ui.counts'` handler). Goes to the
    /// same canonical-mode pool as `publish` — an IDE-client connection folds
    /// into that pool the moment it registers (UnixSocketServer), so this
    /// reaches it on the connection it already has open. Not a
    /// `CanonicalEvent`, so it can't go through `publish`: `station tail`'s
    /// canonical-mode reader tries to decode every line as one and just skips
    /// whatever doesn't fit, which is exactly what should happen here.
    public func publishCounts(running: Int, needsAttention: Int) {
        let dict: [String: Any] = ["event": "ui.counts", "running": running, "needs_attention": needsAttention]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        broadcast(data, toRaw: false)
    }

    private func broadcast(_ payload: Data, toRaw wantsRaw: Bool) {
        var line = payload
        line.append(0x0A)

        lock.lock()
        let fds = subscribers.filter { $0.value == wantsRaw }.map(\.key)
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
        for fd in dead { subscribers[fd] = nil }
        lock.unlock()
        for fd in dead { close(fd) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
