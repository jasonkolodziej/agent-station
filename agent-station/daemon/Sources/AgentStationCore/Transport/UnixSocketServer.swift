import Foundation

/// AF_UNIX, mode 0600, JSON Lines, 256KB frame cap (ARCHITECTURE.md §12).
/// Not TCP: no port, no localhost attack surface, and peer identity is free.
public actor UnixSocketServer {
    public static var defaultPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AgentStation/agentstation.sock")
    }

    public init(path: URL = UnixSocketServer.defaultPath) {}

    /// LOCAL_PEERCRED uid check on every connection.
    /// Code-signature validation of the peer binary is required for the
    /// DECISION channel only — approving `rm -rf` is a privileged act,
    /// reporting a completion is not.
    public func start() async throws { /* TODO(M0b) */ }
}
