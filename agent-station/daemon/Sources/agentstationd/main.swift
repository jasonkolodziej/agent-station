import Foundation
import AgentStationCore

// LaunchAgent entrypoint. KeepAlive=true — this is the only always-on receiver
// for hooks that fire from processes we don't control, at times the UI may not
// be running.
@main
struct Daemon {
    static func main() async throws {
        let server = UnixSocketServer()
        try await server.start()
        // TODO(M0b): wire Normalizer -> Store -> AttentionArbiter -> subscribers
        dispatchMain()
    }
}
