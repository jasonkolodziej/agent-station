import ArgumentParser
import AgentStationCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

@main
struct Station: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Agent Station CLI",
        subcommands: [Tail.self, Doctor.self, Provider.self, Jump.self]
    )
}

/// The M0b deliverable: prove ingress works with no UI at all.
struct Tail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream canonical events as they arrive")

    @Flag(name: .long, help: "Print each event's raw wire JSON instead of a formatted summary.")
    var raw = false

    func run() async throws {
        // `station tail` is a live-streaming tool: default C stdio buffering
        // (fully block-buffered whenever stdout isn't a tty — a pipe, a file,
        // this environment's own captured output) would silently hold events
        // back until a ~4KB buffer fills, or drop them outright if the
        // process is signaled rather than exited cleanly. Neither is
        // acceptable for something whose entire job is "show it now."
        setvbuf(stdout, nil, _IONBF, 0)

        guard DaemonClient.isDaemonReachable() else {
            print("agentstationd is not running — no socket at \(UnixSocketServer.defaultPath.path)")
            print("Start it first: .build/debug/agentstationd")
            throw ExitCode.failure
        }
        print("Tailing \(UnixSocketServer.defaultPath.path) — Ctrl-C to stop.")

        let wantRaw = raw
        try DaemonClient.tail(
            onEvent: { event in
                if wantRaw {
                    if let data = try? Self.rawEncoder.encode(event), let s = String(data: data, encoding: .utf8) {
                        print(s)
                    }
                } else {
                    print(Self.format(event))
                }
            },
            onDisconnect: {
                print("agentstationd closed the connection.")
            }
        )
    }

    private static let rawEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static func format(_ event: CanonicalEvent) -> String {
        var line = "\(ISO8601DateFormatter().string(from: event.ts))  "
            + "\(event.provider.rawValue)".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "  \(event.kind.rawValue)"
        if let title = event.payload.title { line += "  — \(title)" }
        return line
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check wiring, permissions, unmapped provider events")

    func run() async throws {
        let reachable = DaemonClient.isDaemonReachable()
        print(reachable
            ? "daemon:  running  (\(UnixSocketServer.defaultPath.path))"
            : "daemon:  NOT running  (no socket at \(UnixSocketServer.defaultPath.path))")

        let storePath = Self.defaultStorePath()
        guard FileManager.default.fileExists(atPath: storePath.path) else {
            print("store:   no database yet at \(storePath.path)")
            return
        }

        let store = try Store(path: storePath)
        let unmapped = try store.unmappedEvents()
        if unmapped.isEmpty {
            print("unmapped events: none")
        } else {
            // Visible failure, not silent — ARCHITECTURE.md §14. A provider
            // changing its hook schema shows up here, not as a mystery outage.
            print("unmapped events: \(unmapped.count) provider_event kind(s) matched no manifest rule")
            for row in unmapped {
                print("  \(row.provider)/\(row.providerEvent)  ×\(row.count)  last seen \(row.lastSeenAt)")
            }
        }
    }

    private static func defaultStorePath() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTSTATION_STORE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AgentStation/store.sqlite")
    }
}

struct Provider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage provider manifests",
        subcommands: [Validate.self, List.self])

    /// Applies + reverts the install patch against a scratch config dir.
    /// Step 4 of the "adding a new agent" checklist (ARCHITECTURE.md §15).
    /// Needs the M6 manifest-loading + install-patch engine (json-merge,
    /// toml-root-key, json-patch) before this can validate a manifest that
    /// didn't ship built into the daemon — see AdapterRegistry.
    struct Validate: AsyncParsableCommand {
        @Argument var id: String
        func run() async throws {
            print("provider validate: not implemented until M6 (manifest loading + install-patch engine).")
            print("See ARCHITECTURE.md §15 and docs/adr/0004-vscode-first.md.")
            throw ExitCode.failure
        }
    }

    struct List: AsyncParsableCommand {
        func run() async throws {
            let registry = AdapterRegistry()
            let manifests = await registry.allManifests()
            for m in manifests {
                let cap = m.capabilities
                print("\(m.provider.id)  (class \(m.provider.integrationClass.rawValue.uppercased()), \(m.provider.maturity.rawValue))")
                print("  inline_approval=\(cap.inlineApproval)  turn_events=\(cap.turnEvents)  usage_stream=\(cap.usageStream)")
            }
        }
    }
}

struct Jump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a session's owning window")
    @Argument var sessionID: String

    func run() async throws {
        // FocusRouter (§8) is still a stub — this is M2 scope.
        print("station jump: not implemented until M2 (Focus Router).")
        throw ExitCode.failure
    }
}
