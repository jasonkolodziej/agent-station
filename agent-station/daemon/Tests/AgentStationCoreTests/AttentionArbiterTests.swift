import Foundation
import XCTest
@testable import AgentStationCore

// TODO(M0b): AttentionArbiter has no AppKit dep — test priority ladder, coalescing, and the already-looking downgrade in isolation.
final class AttentionArbiterTests: XCTestCase {
    private func neutralContext() -> ArbiterContext {
        ArbiterContext(doNotDisturb: false, breakThroughOnBlocking: false)
    }

    private func event(
        kind: EventKind, sessionID: String = "cc:test", risk: Risk? = nil,
        deadlineMS: Int? = nil, focus: FocusContext? = nil
    ) -> CanonicalEvent {
        CanonicalEvent(
            kind: kind, ts: Date(), provider: "claude-code",
            session: SessionRef(id: sessionID, cwd: "/tmp", surface: .terminal, startedAt: Date()),
            focus: focus,
            payload: EventPayload(risk: risk, decisionChannel: .none, deadlineMS: deadlineMS))
    }

    // MARK: - Priority ladder

    func testHighRiskNearDeadlineApprovalIsBlocking() async {
        let arbiter = AttentionArbiter()
        let outcome = await arbiter.admit(
            event(kind: .approvalRequested, risk: .high, deadlineMS: 5_000),
            context: neutralContext())
        guard case .expand(let activity) = outcome else {
            return XCTFail("expected .expand, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .blocking)
    }

    func testLowRiskApprovalIsAttentionNotBlocking() async {
        let arbiter = AttentionArbiter()
        let outcome = await arbiter.admit(
            event(kind: .approvalRequested, risk: .low), context: neutralContext())
        guard case .expand(let activity) = outcome else {
            return XCTFail("expected .expand, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .attention)
    }

    func testErrorRaisedIsErrorPriority() async {
        let arbiter = AttentionArbiter()
        let outcome = await arbiter.admit(event(kind: .errorRaised), context: neutralContext())
        guard case .expand(let activity) = outcome else {
            return XCTFail("expected .expand, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .error)
    }

    func testTurnCompletedIsForegroundCompactPill() async {
        let arbiter = AttentionArbiter()
        let outcome = await arbiter.admit(event(kind: .turnCompleted), context: neutralContext())
        guard case .compact(let activity) = outcome else {
            return XCTFail("expected .compact, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .foreground)
    }

    func testToolStartedIsAmbient() async {
        let arbiter = AttentionArbiter()
        let outcome = await arbiter.admit(event(kind: .toolStarted, sessionID: "cc:ambient-only"), context: neutralContext())
        guard case .ambient(let activity) = outcome else {
            return XCTFail("expected .ambient, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .ambient)
    }

    // MARK: - Coalescing

    func testRapidToolEventsFromSameSessionCoalesce() async {
        let arbiter = AttentionArbiter()
        _ = await arbiter.admit(event(kind: .toolStarted, sessionID: "cc:burst"), context: neutralContext())
        let second = await arbiter.admit(event(kind: .toolCompleted, sessionID: "cc:burst"), context: neutralContext())
        guard case .suppressed(let reason) = second else {
            return XCTFail("expected the second rapid tool event to be suppressed, got \(second)")
        }
        XCTAssertEqual(reason, "coalesced")
    }

    func testAcknowledgedTurnCompletionIsNotReAlerted() async {
        let arbiter = AttentionArbiter()
        let sessionID = "cc:ack-test"
        _ = await arbiter.admit(event(kind: .turnCompleted, sessionID: sessionID), context: neutralContext())
        await arbiter.acknowledge(sessionID: sessionID)

        let repeatOutcome = await arbiter.admit(event(kind: .turnCompleted, sessionID: sessionID), context: neutralContext())
        guard case .suppressed(let reason) = repeatOutcome else {
            return XCTFail("expected repeat turn.completed to be suppressed once acknowledged, got \(repeatOutcome)")
        }
        XCTAssertEqual(reason, "already acknowledged")
    }

    // MARK: - "Already looking" downgrade

    func testApprovalIsDowngradedWhenUserIsAlreadyFocusedOnTheOwningIDEWindow() async {
        let arbiter = AttentionArbiter()
        let focus = FocusContext(vscodePID: 1234, ideWindowID: "win-1", hostPID: 1234)
        var context = neutralContext()
        context.focusedWindowID = "win-1"

        // Low risk -> .attention (rawValue 1) baseline; downgraded by 2 ->
        // rawValue 3 -> .foreground, which renders as a compact pill rather
        // than the full expand/hold treatment an unseen approval would get.
        let outcome = await arbiter.admit(
            event(kind: .approvalRequested, risk: .low, focus: focus), context: context)
        guard case .compact(let activity) = outcome else {
            return XCTFail("expected .compact (downgraded to .foreground), got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .foreground)
    }

    func testApprovalIsNotDowngradedWhenUserIsLookingElsewhere() async {
        let arbiter = AttentionArbiter()
        let focus = FocusContext(vscodePID: 1234, ideWindowID: "win-1", hostPID: 1234)
        var context = neutralContext()
        context.focusedWindowID = "some-other-window"

        let outcome = await arbiter.admit(
            event(kind: .approvalRequested, risk: .low, focus: focus), context: context)
        guard case .expand(let activity) = outcome else {
            return XCTFail("expected .expand (no downgrade), got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .attention)
    }

    // MARK: - Do Not Disturb

    /// DND never fully silences attention-or-higher urgency (rawValue <= .attention):
    /// it's downgraded to a background badge instead, never a true expand — but
    /// also never nothing. Full suppression is reserved for things that were
    /// already low priority before DND applied.
    func testDoNotDisturbDowngradesAttentionToBackgroundBadge() async {
        let arbiter = AttentionArbiter()
        var context = neutralContext()
        context.doNotDisturb = true

        let outcome = await arbiter.admit(event(kind: .approvalRequested, risk: .low), context: context)
        guard case .badge(let activity) = outcome else {
            return XCTFail("expected .badge (downgraded to .background) under DND, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .background)
    }

    func testDoNotDisturbSuppressesAlreadyLowPriorityEvents() async {
        let arbiter = AttentionArbiter()
        var context = neutralContext()
        context.doNotDisturb = true

        // turnCompleted's base priority is .foreground, already below
        // .attention, so DND suppresses it outright rather than downgrading.
        let outcome = await arbiter.admit(event(kind: .turnCompleted), context: context)
        guard case .suppressed(let reason) = outcome else {
            return XCTFail("expected .suppressed under DND, got \(outcome)")
        }
        XCTAssertEqual(reason, "do not disturb")
    }

    // MARK: - needsAttentionCount (ui.counts' `needs_attention`)

    func testNeedsAttentionCountsOnlyBlockingAttentionAndErrorUnacknowledged() async {
        let arbiter = AttentionArbiter()
        _ = await arbiter.admit(event(kind: .approvalRequested, sessionID: "cc:blocking", risk: .high, deadlineMS: 1_000), context: neutralContext())
        _ = await arbiter.admit(event(kind: .errorRaised, sessionID: "cc:error"), context: neutralContext())
        // foreground/ambient priorities shouldn't count even though they're "live".
        _ = await arbiter.admit(event(kind: .turnCompleted, sessionID: "cc:foreground"), context: neutralContext())
        _ = await arbiter.admit(event(kind: .toolStarted, sessionID: "cc:ambient"), context: neutralContext())

        let count = await arbiter.needsAttentionCount()
        XCTAssertEqual(count, 2)
    }

    func testNeedsAttentionCountExcludesAcknowledgedSessions() async {
        let arbiter = AttentionArbiter()
        _ = await arbiter.admit(event(kind: .turnCompleted, sessionID: "cc:done"), context: neutralContext())
        // turnCompleted alone isn't attention-worthy; use an approval instead.
        _ = await arbiter.admit(event(kind: .approvalRequested, sessionID: "cc:approval", risk: .low), context: neutralContext())
        let beforeAck = await arbiter.needsAttentionCount()
        XCTAssertEqual(beforeAck, 1)

        await arbiter.acknowledge(sessionID: "cc:approval")
        let afterAck = await arbiter.needsAttentionCount()
        XCTAssertEqual(afterAck, 0)
    }

    func testRetireRemovesTheSessionFromNeedsAttentionCount() async {
        let arbiter = AttentionArbiter()
        _ = await arbiter.admit(event(kind: .approvalRequested, sessionID: "cc:ending", risk: .high, deadlineMS: 1_000), context: neutralContext())
        let beforeRetire = await arbiter.needsAttentionCount()
        XCTAssertEqual(beforeRetire, 1)

        await arbiter.retire(sessionID: "cc:ending")

        let afterRetire = await arbiter.needsAttentionCount()
        XCTAssertEqual(afterRetire, 0)
    }

    func testDoNotDisturbLetsBlockingThroughWhenOptedIn() async {
        let arbiter = AttentionArbiter()
        var context = neutralContext()
        context.doNotDisturb = true
        context.breakThroughOnBlocking = true

        let outcome = await arbiter.admit(
            event(kind: .approvalRequested, risk: .high, deadlineMS: 1_000), context: context)
        guard case .expand(let activity) = outcome else {
            return XCTFail("expected P0 to break through DND, got \(outcome)")
        }
        XCTAssertEqual(activity.priority, .blocking)
    }
}
