import Foundation

/// The vocabulary every provider collapses into. See ARCHITECTURE.md §3.
///
/// Deliberately small. Resist adding a case for something only one provider
/// emits — put it in `payload` and let the UI ignore it. Every case added here
/// is a case the arbiter, the store, and the panel all have to reason about.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case sessionStarted    = "session.started"
    case sessionEnded      = "session.ended"
    case turnStarted       = "turn.started"
    case turnCompleted     = "turn.completed"
    case attentionRequired = "attention.required"
    case approvalRequested = "approval.requested"
    case approvalResolved  = "approval.resolved"
    case toolStarted       = "tool.started"
    case toolCompleted     = "tool.completed"
    case usageSampled      = "usage.sampled"
    case errorRaised       = "error.raised"
}

public enum Surface: String, Codable, Sendable {
    case terminal, ide, cloud, headless
}

/// Where a decision for this event can be made. Drives whether the island shows
/// an Approve button or a Jump button — the single most important honesty
/// affordance in the product (ARCHITECTURE.md §4.1).
public enum DecisionChannel: String, Codable, Sendable {
    /// Provider can block and accept a reply (Claude Code, Cursor, Gemini CLI).
    case inline
    /// Provider notified us but cannot accept a reply (Codex). Jump only.
    case terminalOnly = "terminal_only"
    /// Informational.
    case none
}

public enum Risk: String, Codable, Sendable, Comparable {
    case low, medium, high
    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }
}

public struct SessionRef: Codable, Sendable, Hashable {
    public let id: String            // provider-scoped, stable for run lifetime
    public var projectID: String?    // resolved async — nil on the ingress path
    public let cwd: String
    public let surface: Surface
    public var model: String?
    public let startedAt: Date

    public init(id: String, projectID: String? = nil, cwd: String, surface: Surface, model: String? = nil, startedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.cwd = cwd
        self.surface = surface
        self.model = model
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case cwd
        case surface
        case model
        case startedAt = "started_at"
    }
}

/// Captured ONCE, at session start, from the shim's own environment.
/// Unrecoverable later — see ARCHITECTURE.md §8.
public struct FocusContext: Codable, Sendable, Hashable {
    public var termProgram: String?
    public var itermSessionID: String?
    public var termSessionID: String?
    public var weztermPane: String?
    public var kittyWindowID: String?
    public var tmux: String?
    public var tmuxPane: String?
    public var zellijSession: String?
    public var vscodePID: Int?
    public var vscodeCWD: String?
    public var ideWindowID: String?
    public var workspaceURI: String?
    public var hostPID: Int
    public var sshTTY: String?
    /// The shim's own `cwd` at capture time — distinct from `vscodeCWD`, which
    /// is the IDE workspace root. See schema/canonical-event.schema.json.
    public var cwd: String?

    public init(
        termProgram: String? = nil, itermSessionID: String? = nil, termSessionID: String? = nil,
        weztermPane: String? = nil, kittyWindowID: String? = nil, tmux: String? = nil,
        tmuxPane: String? = nil, zellijSession: String? = nil, vscodePID: Int? = nil,
        vscodeCWD: String? = nil, ideWindowID: String? = nil, workspaceURI: String? = nil,
        hostPID: Int, sshTTY: String? = nil, cwd: String? = nil
    ) {
        self.termProgram = termProgram
        self.itermSessionID = itermSessionID
        self.termSessionID = termSessionID
        self.weztermPane = weztermPane
        self.kittyWindowID = kittyWindowID
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.zellijSession = zellijSession
        self.vscodePID = vscodePID
        self.vscodeCWD = vscodeCWD
        self.ideWindowID = ideWindowID
        self.workspaceURI = workspaceURI
        self.hostPID = hostPID
        self.sshTTY = sshTTY
        self.cwd = cwd
    }

    /// True when the session runs inside an IDE integrated terminal, which
    /// means routing should go through the extension rather than AX.
    public var isIDEHosted: Bool {
        vscodePID != nil || termProgram == "vscode" || ideWindowID != nil
    }

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case itermSessionID = "iterm_session_id"
        case termSessionID = "term_session_id"
        case weztermPane = "wezterm_pane"
        case kittyWindowID = "kitty_window_id"
        case tmux
        case tmuxPane = "tmux_pane"
        case zellijSession = "zellij_session"
        case vscodePID = "vscode_pid"
        case vscodeCWD = "vscode_cwd"
        case ideWindowID = "ide_window_id"
        case workspaceURI = "workspace_uri"
        case hostPID = "host_pid"
        case sshTTY = "ssh_tty"
        case cwd
    }
}

public struct EventPayload: Codable, Sendable {
    public var kind: String?          // approval | input | elicitation | idle
    public var title: String?
    public var detail: String?
    public var risk: Risk?
    public var decisionChannel: DecisionChannel
    public var deadlineMS: Int?
    /// Provider-specific extras the core does not interpret.
    public var extra: [String: String]?

    public init(
        kind: String? = nil, title: String? = nil, detail: String? = nil, risk: Risk? = nil,
        decisionChannel: DecisionChannel, deadlineMS: Int? = nil, extra: [String: String]? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.risk = risk
        self.decisionChannel = decisionChannel
        self.deadlineMS = deadlineMS
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, detail, risk
        case decisionChannel = "decision_channel"
        case deadlineMS = "deadline_ms"
        case extra
    }
}

public struct CanonicalEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let v: Int
    public let kind: EventKind
    public let ts: Date
    public let provider: ProviderID
    /// Preserved verbatim. When a provider changes its schema this is the only
    /// thing that lets you debug the break.
    public let providerEvent: String?
    public var session: SessionRef
    public var focus: FocusContext?
    public var payload: EventPayload
    /// Present iff payload.decisionChannel == .inline. Single-use, expires with
    /// the prompt deadline.
    public var replyToken: String?

    public init(
        id: UUID = UUID(), v: Int = 1, kind: EventKind, ts: Date, provider: ProviderID,
        providerEvent: String? = nil, session: SessionRef, focus: FocusContext? = nil,
        payload: EventPayload, replyToken: String? = nil
    ) {
        self.id = id
        self.v = v
        self.kind = kind
        self.ts = ts
        self.provider = provider
        self.providerEvent = providerEvent
        self.session = session
        self.focus = focus
        self.payload = payload
        self.replyToken = replyToken
    }

    enum CodingKeys: String, CodingKey {
        case id, v
        case kind = "event"
        case ts, provider
        case providerEvent = "provider_event"
        case session, focus, payload
        case replyToken = "reply_token"
    }
}
