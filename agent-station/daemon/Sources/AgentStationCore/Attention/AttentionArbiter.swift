import Foundation

/// One notch, N agents. This is the piece that makes Agent Station better than
/// N separate notification banners — see ARCHITECTURE.md §6.
///
/// Testable in isolation on purpose: no AppKit import, no panel reference. The
/// arbiter decides WHAT deserves attention; the panel decides how to draw it.
public enum Priority: Int, Comparable, Sendable {
    case ambient   = 5   // P5 tool/progress — ear glyph only
    case background = 4  // P4 completion elsewhere — badge increment
    case foreground = 3  // P3 completion on a relevant project — compact pill
    case error      = 2  // P2 — expand 4s then badge
    case attention  = 1  // P1 — expand and hold
    case blocking   = 0  // P0 high-risk approval near deadline — expand, hold, sound

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

public struct Activity: Sendable, Identifiable {
    public let id: String            // session id
    public var priority: Priority
    public var event: CanonicalEvent
    public var createdAt: Date
    public var acknowledged: Bool = false
}

public struct ArbiterContext: Sendable {
    /// Frontmost app bundle id, and the AX-focused window if resolvable.
    public var frontmostBundleID: String?
    public var focusedWindowID: String?
    /// True when a Focus mode / DND is engaged.
    public var doNotDisturb: Bool
    public var breakThroughOnBlocking: Bool  // opt-in, off by default

    public init(frontmostBundleID: String? = nil, focusedWindowID: String? = nil, doNotDisturb: Bool, breakThroughOnBlocking: Bool) {
        self.frontmostBundleID = frontmostBundleID
        self.focusedWindowID = focusedWindowID
        self.doNotDisturb = doNotDisturb
        self.breakThroughOnBlocking = breakThroughOnBlocking
    }
}

public actor AttentionArbiter {
    /// Same-session events inside this window coalesce. Agents emit bursts.
    private static let coalesceWindow: TimeInterval = 0.4

    private var live: [String: Activity] = [:]
    private var lastEventAt: [String: Date] = [:]
    private var acknowledgedTurns: Set<String> = []

    public init() {}

    public enum Outcome: Sendable {
        case expand(Activity)
        case compact(Activity)
        case badge(Activity)
        case ambient(Activity)
        case suppressed(reason: String)
    }

    public func admit(_ event: CanonicalEvent, context: ArbiterContext) -> Outcome {
        // 1. Coalesce bursts from the same session.
        if let last = lastEventAt[event.session.id],
           Date().timeIntervalSince(last) < Self.coalesceWindow,
           event.kind == .toolStarted || event.kind == .toolCompleted {
            return .suppressed(reason: "coalesced")
        }
        lastEventAt[event.session.id] = Date()

        // 2. Never re-alert an acknowledged completion.
        if event.kind == .turnCompleted, acknowledgedTurns.contains(event.session.id) {
            return .suppressed(reason: "already acknowledged")
        }

        var priority = Self.basePriority(for: event)

        // 3. THE rule that earns trust: if the user is already looking at the
        //    window that owns this session, downgrade two levels. Nobody needs
        //    a notch alert about the terminal they are staring at.
        if isUserAlreadyLooking(at: event, context: context) {
            priority = Self.downgrade(priority, by: 2)
        }

        // 4. Respect Focus modes. P0 may break through only if opted in.
        if context.doNotDisturb {
            if priority == .blocking && context.breakThroughOnBlocking {
                // fall through
            } else if priority <= .attention {
                priority = .background
            } else {
                return .suppressed(reason: "do not disturb")
            }
        }

        let activity = Activity(id: event.session.id, priority: priority,
                                event: event, createdAt: Date())
        live[event.session.id] = activity

        // 5. Only one expanded activity at a time. Losers stack into the ear.
        switch priority {
        case .blocking, .attention, .error:
            if let incumbent = currentlyExpanded(), incumbent.priority < priority {
                return .badge(activity)   // incumbent outranks; queue behind it
            }
            return .expand(activity)
        case .foreground: return .compact(activity)
        case .background: return .badge(activity)
        case .ambient:    return .ambient(activity)
        }
    }

    public func acknowledge(sessionID: String) {
        acknowledgedTurns.insert(sessionID)
        live[sessionID]?.acknowledged = true
    }

    public func retire(sessionID: String) {
        live[sessionID] = nil
        lastEventAt[sessionID] = nil
        acknowledgedTurns.remove(sessionID)
    }

    // MARK: - Private

    private func currentlyExpanded() -> Activity? {
        live.values
            .filter { !$0.acknowledged && $0.priority <= .error }
            .min { $0.priority < $1.priority }
    }

    private func isUserAlreadyLooking(at event: CanonicalEvent, context: ArbiterContext) -> Bool {
        guard let focus = event.focus else { return false }
        if focus.isIDEHosted, let win = focus.ideWindowID {
            return context.focusedWindowID == win
        }
        if let term = focus.termProgram, let front = context.frontmostBundleID {
            // Coarse for terminals — we know the app, not always the pane.
            // Deliberately conservative: only suppress when we can also match
            // the pane, otherwise a background tab would go silent.
            let appMatches = front.localizedCaseInsensitiveContains(term.replacingOccurrences(of: ".app", with: ""))
            let paneKnown = focus.itermSessionID != nil || focus.tmuxPane != nil
            return appMatches && paneKnown && context.focusedWindowID == focus.itermSessionID
        }
        return false
    }

    private static func basePriority(for event: CanonicalEvent) -> Priority {
        switch event.kind {
        case .approvalRequested, .attentionRequired:
            let urgent = (event.payload.risk ?? .low) == .high
            let soon = (event.payload.deadlineMS ?? .max) < 10_000
            return (urgent && soon) ? .blocking : .attention
        case .errorRaised:
            return .error
        case .turnCompleted:
            return .foreground   // demoted to .background by project relevance
        case .toolStarted, .toolCompleted, .turnStarted:
            return .ambient
        case .sessionStarted, .sessionEnded, .approvalResolved, .usageSampled:
            return .ambient
        }
    }

    private static func downgrade(_ p: Priority, by n: Int) -> Priority {
        Priority(rawValue: min(p.rawValue + n, Priority.ambient.rawValue)) ?? .ambient
    }
}
