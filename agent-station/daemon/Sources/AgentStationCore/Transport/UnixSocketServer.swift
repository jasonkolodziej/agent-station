import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// AF_UNIX, mode 0600, JSON Lines, 256KB frame cap (ARCHITECTURE.md §12).
/// Not TCP: no port, no localhost attack surface, and peer identity is free.
///
/// M0b scope: ingestion only. The shim writes one envelope line per
/// connection and either returns immediately or blocks reading a decision
/// reply (`--await-decision`) with its own 8s timeout. This server never
/// writes a reply — it just accepts, reads one line, hands it off, and closes.
/// That closes the socket promptly under an `--await-decision` shim too: EOF
/// with no bytes means "no decision", which is exactly the fail-open behaviour
/// the shim already implements (ARCHITECTURE.md §14 — we never auto-approve).
/// Wiring an actual decision reply is M4 scope (reply tokens + inline UI).
public actor UnixSocketServer {
    /// Overridable via `AGENTSTATION_SOCKET_PATH` — matches the VS Code
    /// extension's `agentStation.socketPath` setting, and lets tests/dev runs
    /// avoid touching the real per-user Application Support directory.
    public static var defaultPath: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTSTATION_SOCKET_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AgentStation/agentstation.sock")
    }

    /// 256 KB, matching the shim's own MAX_PAYLOAD_BYTES cap.
    public static let maxFrameBytes = 256 * 1024

    public typealias EnvelopeHandler = @Sendable (RawEvent) -> Void

    public enum ServerError: Error, Sendable {
        case socketCreationFailed(errno: Int32)
        case pathTooLong
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }

    private let path: URL
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    public init(path: URL = UnixSocketServer.defaultPath) {
        self.path = path
    }

    /// Binds, listens, and starts accepting on a dedicated background thread
    /// (not the cooperative Swift concurrency pool — accept()/read() block).
    /// `onEnvelope` is invoked from arbitrary connection-handler threads; it
    /// must be safe to call concurrently. `subscribers`, if given, receives
    /// connections that open with `{"op":"subscribe"}` instead of a hook
    /// envelope — see SubscriberHub. `windows`, if given, receives the VS
    /// Code extension's `ide.window.*`/`ide.terminal.*` connections — see
    /// WindowRegistry and ARCHITECTURE.md §7.2.
    public func start(
        subscribers: SubscriberHub? = nil, windows: WindowRegistry? = nil,
        suppressionRules: [String: [String]] = [:],
        onEnvelope: @escaping EnvelopeHandler
    ) throws {
        guard listenFD < 0 else { return }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pathString = path.path
        // Stale socket file from a previous run that didn't shut down cleanly.
        unlink(pathString)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreationFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(pathString.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0 // NUL terminator
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw ServerError.bindFailed(errno: err)
        }

        chmod(pathString, 0o600)

        guard listen(fd, 64) == 0 else {
            let err = errno
            close(fd)
            throw ServerError.listenFailed(errno: err)
        }

        listenFD = fd

        let thread = Thread {
            Self.acceptLoop(
                listenFD: fd, subscribers: subscribers, windows: windows,
                suppressionRules: suppressionRules, onEnvelope: onEnvelope)
        }
        thread.name = "agentstationd.uds-accept"
        thread.start()
        acceptThread = thread
    }

    public func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(path.path)
        acceptThread = nil
    }

    // MARK: - Blocking I/O, off the actor (deliberately `nonisolated static`:
    // this is plain POSIX code with no access to actor state).

    private nonisolated static func acceptLoop(
        listenFD: Int32, subscribers: SubscriberHub?, windows: WindowRegistry?,
        suppressionRules: [String: [String]], onEnvelope: @escaping EnvelopeHandler
    ) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                // EBADF/EINVAL: the listening socket was closed out from under
                // us (stop()). Anything else: keep accepting.
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            let connectionThread = Thread {
                Self.handleConnection(
                    fd: clientFD, subscribers: subscribers, windows: windows,
                    suppressionRules: suppressionRules, onEnvelope: onEnvelope)
            }
            connectionThread.start()
        }
    }

    private nonisolated static func handleConnection(
        fd: Int32, subscribers: SubscriberHub?, windows: WindowRegistry?,
        suppressionRules: [String: [String]], onEnvelope: @escaping EnvelopeHandler
    ) {
        // Peer validation (ARCHITECTURE.md §12): the connecting process must
        // run as the same user. getpeereid is macOS/BSD's LOCAL_PEERCRED
        // equivalent. Code-signature validation is reserved for the decision
        // channel, which this server doesn't implement yet (M4).
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            close(fd)
            return
        }

        guard let line = readOneJSONValue(fd: fd, cap: maxFrameBytes) else {
            close(fd)
            return
        }

        if let wantsRaw = subscribeMode(line), let subscribers {
            subscribers.add(fd: fd, raw: wantsRaw)
            // Block until the peer disconnects, so we know when to drop it
            // from the broadcast set. We never read a second request off a
            // subscriber connection — it's push-only from here on.
            var discard = [UInt8](repeating: 0, count: 256)
            while true {
                let n = discard.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
            }
            subscribers.remove(fd: fd)
            close(fd)
            return
        }

        if isIDEMessage(line) {
            // Unlike a hook envelope (one shot) or a subscriber (push-only
            // after the first line), a VS Code window is genuinely
            // multi-message: it sends window.registered once, then
            // window.focus / terminal.open / terminal.close for as long as
            // the window is open. Fold it into the canonical-event broadcast
            // too, so the extension's status bar sees live events on the same
            // connection it already opened — one persistent connection per
            // window, matching daemonClient.ts's reconnect-loop design.
            subscribers?.add(fd: fd, raw: false)
            var current: Data? = line
            while let message = current {
                dispatchIDEMessage(message, fd: fd, windows: windows, suppressionRules: suppressionRules)
                current = readOneJSONValue(fd: fd, cap: maxFrameBytes)
            }
            windows?.unregister(fd: fd) // safety net if unregistered wasn't sent explicitly
            subscribers?.remove(fd: fd)
            close(fd)
            return
        }

        defer { close(fd) }
        guard let envelope = parseEnvelope(line) else { return }
        onEnvelope(envelope)
        // Connection closes here (defer), which is the "no decision" signal
        // an --await-decision shim is already built to fail open on.
    }

    /// `{"op":"subscribe"}` for canonical events, `{"op":"subscribe","raw":true}`
    /// for the verbatim-payload capture channel `station tail --raw` uses.
    /// Returns nil if this isn't a subscribe request at all.
    private nonisolated static func subscribeMode(_ line: Data) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["op"] as? String) == "subscribe"
        else { return nil }
        return (obj["raw"] as? Bool) ?? false
    }

    /// True for any of the VS Code extension's `ide.*` messages
    /// (ARCHITECTURE.md §7.2) — `windowIdentity.ts`'s `registerWindowIdentity`
    /// and `bindIntegratedTerminals`.
    private nonisolated static func isIDEMessage(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = obj["event"] as? String
        else { return false }
        return event.hasPrefix("ide.")
    }

    /// Dispatches one message from an IDE-client connection. `ui.expand_requested`
    /// (the extension also sends this over the same connection) isn't handled
    /// here — it belongs to the notch panel, which doesn't exist yet (M3) —
    /// and is silently accepted-but-ignored rather than misrouted.
    private nonisolated static func dispatchIDEMessage(
        _ line: Data, fd: Int32, windows: WindowRegistry?, suppressionRules: [String: [String]]
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = obj["event"] as? String
        else { return }

        switch event {
        case "ide.window.registered":
            guard let identity = parseWindowIdentity(obj) else { return }
            windows?.register(fd: fd, identity: identity)
        case "ide.window.focus":
            windows?.setFocused(fd: fd, focused: (obj["focused"] as? Bool) ?? false)
        case "ide.window.unregistered":
            windows?.unregister(fd: fd)
        case "ide.terminal.open":
            guard let pid = intValue(obj["terminal_pid"]) else { return }
            windows?.bindTerminal(pid: pid, toWindowFD: fd)
        case "ide.terminal.close":
            guard let pid = intValue(obj["terminal_pid"]) else { return }
            windows?.unbindTerminal(pid: pid)
        case "query.suppression_rules":
            replySuppressionRules(fd: fd, suppressionRules: suppressionRules)
        default:
            break
        }
    }

    private nonisolated static func parseWindowIdentity(_ obj: [String: Any]) -> WindowIdentity? {
        guard let ide = obj["ide"] as? String,
              let windowID = obj["window_id"] as? String,
              let uriScheme = obj["uri_scheme"] as? String
        else { return nil }
        return WindowIdentity(
            ide: ide, windowID: windowID, pid: intValue(obj["pid"]) ?? 0,
            workspaceRoots: (obj["workspace_roots"] as? [String]) ?? [],
            uriScheme: uriScheme, remoteName: obj["remote_name"] as? String)
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }

    /// Answers `query.suppression_rules` directly on the asking connection —
    /// a targeted reply, not a broadcast, so this writes straight to `fd`
    /// rather than going through SubscriberHub. `settingsManager.ts`'s
    /// `apply()` is the eventual consumer; it stays unreachable from the
    /// command palette until this returns something non-empty for at least
    /// one provider, which today means none — see ProviderManifest's
    /// `NotificationSuppression` doc comment on why these keys are seeded
    /// empty rather than guessed.
    private nonisolated static func replySuppressionRules(fd: Int32, suppressionRules: [String: [String]]) {
        let rules = suppressionRules.map { ["provider": $0.key, "keys": $0.value] }
        guard var data = try? JSONSerialization.data(withJSONObject: ["event": "suppression_rules", "rules": rules])
        else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { raw -> Int32 in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return 0
        }
    }

    /// Reads exactly one top-level JSON value (object or array), tracking
    /// brace/bracket depth and string-escape state rather than splitting on
    /// `\n`.
    ///
    /// This is not optional: the shim splices a provider's raw payload into
    /// the envelope *verbatim* and never reformats it (ADR-0003, "the shim
    /// does not parse the payload"). A pretty-printed provider payload —
    /// exactly what the checked-in fixtures look like — puts literal newline
    /// bytes inside the envelope, well before the frame actually ends.
    /// Newline-delimited framing is fundamentally incompatible with
    /// byte-verbatim splicing of arbitrary payloads; only the JSON structure
    /// itself reliably marks the end of a frame.
    ///
    /// Stops as soon as the value is structurally complete rather than
    /// waiting for EOF — important for `--await-decision` connections, which
    /// the shim deliberately keeps open afterward while it waits (up to 8s)
    /// for a reply.
    private nonisolated static func readOneJSONValue(fd: Int32, cap: Int) -> Data? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(4096)
        var chunk = [UInt8](repeating: 0, count: 4096)

        var depth = 0
        var started = false
        var inString = false
        var escaped = false

        while buffer.count < cap {
            let n = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { break } // EOF or error

            for i in 0..<n {
                let byte = chunk[i]
                buffer.append(byte)

                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }

                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    started = true
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if started && depth == 0 {
                        return Data(buffer)
                    }
                default:
                    break
                }
            }
        }
        return buffer.isEmpty ? nil : Data(buffer)
    }

    private nonisolated static func parseEnvelope(_ data: Data) -> RawEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let providerRaw = obj["provider"] as? String else { return nil }

        let provider = ProviderID(rawValue: providerRaw)
        let receivedAt: Date
        if let ms = obj["received_at_ms"] as? Int {
            receivedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else if let ms = obj["received_at_ms"] as? NSNumber {
            receivedAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        } else {
            receivedAt = Date()
        }
        let truncated = obj["truncated"] as? Bool ?? false
        let focus = (obj["focus"] as? [String: Any]).map(decodeFocus)

        let rawData: Data
        if let raw = obj["raw"], !(raw is NSNull) {
            rawData = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data("{}".utf8)
        } else {
            rawData = Data("{}".utf8)
        }

        return RawEvent(provider: provider, receivedAt: receivedAt, focus: focus, raw: rawData, truncated: truncated)
    }

    private nonisolated static func decodeFocus(_ obj: [String: Any]) -> FocusContext {
        func str(_ key: String) -> String? { obj[key] as? String }
        func int(_ key: String) -> Int? {
            (obj[key] as? Int) ?? (obj[key] as? NSNumber)?.intValue ?? Int(str(key) ?? "")
        }
        return FocusContext(
            termProgram: str("term_program"),
            itermSessionID: str("iterm_session_id"),
            termSessionID: str("term_session_id"),
            weztermPane: str("wezterm_pane"),
            kittyWindowID: str("kitty_window_id"),
            tmux: str("tmux"),
            tmuxPane: str("tmux_pane"),
            zellijSession: str("zellij_session"),
            vscodePID: int("vscode_pid"),
            vscodeCWD: str("vscode_cwd"),
            ideWindowID: nil,
            workspaceURI: nil,
            hostPID: int("host_pid") ?? 0,
            sshTTY: str("ssh_tty"),
            cwd: str("cwd")
        )
    }
}
