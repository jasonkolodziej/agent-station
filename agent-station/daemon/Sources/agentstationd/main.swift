import Foundation
import AgentStationCore

// LaunchAgent entrypoint. KeepAlive=true — this is the only always-on receiver
// for hooks that fire from processes we don't control, at times the UI may not
// be running.
@main
struct Daemon {
    static func main() async throws {
        let registry = AdapterRegistry()
        let normalizer = Normalizer()
        let store = try Store(path: Self.defaultStorePath())
        let arbiter = AttentionArbiter()
        let subscribers = SubscriberHub()
        let server = UnixSocketServer()

        try await server.start(subscribers: subscribers) { raw in
            Task {
                await Self.process(
                    raw, registry: registry, normalizer: normalizer,
                    store: store, arbiter: arbiter, subscribers: subscribers)
            }
        }

        FileHandle.standardError.write(Data("agentstationd: listening on \(UnixSocketServer.defaultPath.path)\n".utf8))

        // `dispatchMain()` never returns — but it also traps when called from
        // an async `main()`, because it parks the thread assuming it owns the
        // real OS main thread the way a synchronous `main()` does, which
        // isn't true under Swift concurrency's async main bootstrapping. The
        // async-native equivalent is just never letting this Task finish.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Normalizer -> Store -> AttentionArbiter -> subscribers. No UI exists
    /// yet to consume the arbiter's Outcome (M3); admitting every event now
    /// still exercises coalescing/dedup logic and keeps `live` state warm for
    /// whichever surface attaches first.
    private static func process(
        _ raw: RawEvent, registry: AdapterRegistry, normalizer: Normalizer,
        store: Store, arbiter: AttentionArbiter, subscribers: SubscriberHub
    ) async {
        // Fans out to raw-mode subscribers (`station tail --raw`, the golden
        // fixture capture path fixtures/README.md documents) unconditionally
        // — SubscriberHub is a no-op broadcast when nobody's listening in
        // that mode, so this never costs anything on the hot path.
        subscribers.publishRaw(raw)

        let result: Normalizer.Result
        do {
            result = try await normalizer.normalize(raw, using: registry)
        } catch {
            FileHandle.standardError.write(Data("agentstationd: normalize failed: \(error)\n".utf8))
            return
        }

        if let unmapped = result.unmapped {
            do {
                try store.recordUnmapped(unmapped)
            } catch {
                FileHandle.standardError.write(Data("agentstationd: recordUnmapped failed: \(error)\n".utf8))
            }
        }

        for event in result.events {
            do {
                try store.record(event)
            } catch {
                FileHandle.standardError.write(Data("agentstationd: store.record failed: \(error)\n".utf8))
            }
            subscribers.publish(event)

            // No frontmost-app/AX/DND signal exists yet (that's the notch
            // app's job, M3) — admit with a neutral context so coalescing and
            // acknowledgement bookkeeping stay correct once a UI attaches.
            let context = ArbiterContext(
                frontmostBundleID: nil, focusedWindowID: nil,
                doNotDisturb: false, breakThroughOnBlocking: false)
            _ = await arbiter.admit(event, context: context)
        }
    }

    /// Overridable via `AGENTSTATION_STORE_PATH` — see UnixSocketServer.defaultPath.
    private static func defaultStorePath() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTSTATION_STORE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AgentStation/store.sqlite")
    }
}
