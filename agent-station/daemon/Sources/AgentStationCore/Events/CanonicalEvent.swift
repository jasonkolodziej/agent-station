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

    /// True when the session runs inside an IDE integrated terminal, which
    /// means routing should go through the extension rather than AX.
    public var isIDEHosted: Bool {
        vscodePID != nil || termProgram == "vscode" || ideWindowID != nil
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
}
