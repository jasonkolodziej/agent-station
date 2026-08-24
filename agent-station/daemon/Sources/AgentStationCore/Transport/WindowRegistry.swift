import Foundation

/// Server-side counterpart of the VS Code extension's `registerWindowIdentity()`
/// (ARCHITECTURE.md §7.2). This is the load-bearing piece of F11a: without it,
/// focus routing for IDE-hosted sessions falls all the way through to
/// "activate the app" — right app, wrong tab.
public struct WindowIdentity: Sendable, Codable, Equatable {
    public let ide: String              // "Visual Studio Code" | "Cursor" | ...
    public let windowID: String         // vscode.env.sessionId
    public let pid: Int
    public let workspaceRoots: [String]
    public let uriScheme: String        // "vscode" | "cursor" | "vscode-insiders"
    /// Non-nil means the window is a remote (SSH/WSL/containers) session —
    /// `pid` and any AX-based focus routing are meaningless off-host.
    public let remoteName: String?
    public let registeredAt: Date

    public init(
        ide: String, windowID: String, pid: Int, workspaceRoots: [String],
        uriScheme: String, remoteName: String? = nil, registeredAt: Date = Date()
    ) {
        self.ide = ide
        self.windowID = windowID
        self.pid = pid
        self.workspaceRoots = workspaceRoots
        self.uriScheme = uriScheme
        self.remoteName = remoteName
        self.registeredAt = registeredAt
    }

    enum CodingKeys: String, CodingKey {
        case ide
        case windowID = "window_id"
        case pid
        case workspaceRoots = "workspace_roots"
        case uriScheme = "uri_scheme"
        case remoteName = "remote_name"
        case registeredAt = "registered_at"
    }
}

/// A CLI agent session running in a window's integrated terminal — the cheap
/// half of the §7.4 bridge. No proposed API needed: the shim already captures
/// `VSCODE_PID` from its own environment (ARCHITECTURE.md §8); this is what
/// lets the daemon tell that PID belongs to a specific window.
public struct TerminalBinding: Sendable, Equatable {
    public let terminalPID: Int
    public let name: String
    public let cwd: String?
}

/// Lock-protected, not an actor. Connection handling happens on plain POSIX
/// threads (see UnixSocketServer), not Swift concurrency's cooperative pool —
/// this mirrors SubscriberHub's own reasoning.
public final class WindowRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var byFD: [Int32: WindowIdentity] = [:]
    private var focusedFDs: Set<Int32> = []
    /// terminal pid -> owning window's fd. A terminal can outlive nothing
    /// here it doesn't already depend on: if the window disconnects, its
    /// bindings are dropped with it (see `unregister`).
    private var terminalBindings: [Int: Int32] = [:]

    public init() {}

    public func register(fd: Int32, identity: WindowIdentity) {
        lock.lock()
        byFD[fd] = identity
        lock.unlock()
    }

    /// Drops the window and everything scoped to its connection — focus
    /// state and terminal bindings alike. Called both on an explicit
    /// `ide.window.unregistered` message and, as the safety net, whenever the
    /// connection actually closes (a window can vanish without a clean
    /// unregister — force-quit, crash, lost network for a remote session).
    public func unregister(fd: Int32) {
        lock.lock()
        byFD[fd] = nil
        focusedFDs.remove(fd)
        terminalBindings = terminalBindings.filter { $0.value != fd }
        lock.unlock()
    }

    public func setFocused(fd: Int32, focused: Bool) {
        lock.lock()
        if focused { focusedFDs.insert(fd) } else { focusedFDs.remove(fd) }
        lock.unlock()
    }

    public func bindTerminal(pid: Int, toWindowFD fd: Int32) {
        lock.lock()
        terminalBindings[pid] = fd
        lock.unlock()
    }

    public func unbindTerminal(pid: Int) {
        lock.lock()
        terminalBindings[pid] = nil
        lock.unlock()
    }

    /// The window whose integrated terminal owns this PID — how a CLI
    /// session's `VSCODE_PID` (captured by the shim at session start) resolves
    /// back to an actual open window for focus routing.
    public func window(forTerminalPID pid: Int) -> WindowIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = terminalBindings[pid] else { return nil }
        return byFD[fd]
    }

    /// First registered window whose workspace roots contain — or are an
    /// ancestor of — the given cwd. Ancestor match handles a session running
    /// in a subdirectory of the open workspace (a monorepo package, e.g.).
    public func window(forCwd cwd: String) -> WindowIdentity? {
        lock.lock()
        let identities = Array(byFD.values)
        lock.unlock()
        return identities.first { identity in
            identity.workspaceRoots.contains { root in
                cwd == root || cwd.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }

    public func isFocused(_ identity: WindowIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = byFD.first(where: { $0.value == identity })?.key else { return false }
        return focusedFDs.contains(fd)
    }

    public func all() -> [WindowIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byFD.values)
    }
}
