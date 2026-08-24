import Foundation
import XCTest
@testable import AgentStationCore

final class StoreTests: XCTestCase {
    private func event(kind: EventKind, sessionID: String) -> CanonicalEvent {
        CanonicalEvent(
            kind: kind, ts: Date(), provider: "claude-code",
            session: SessionRef(id: sessionID, cwd: "/tmp", surface: .terminal, startedAt: Date()),
            payload: EventPayload(decisionChannel: .none))
    }

    func testActiveSessionCountCountsOnlySessionsWithoutEndedAt() throws {
        let store = try Store.inMemory()

        try store.record(event(kind: .sessionStarted, sessionID: "cc:a"))
        try store.record(event(kind: .sessionStarted, sessionID: "cc:b"))
        XCTAssertEqual(try store.activeSessionCount(), 2)

        try store.record(event(kind: .sessionEnded, sessionID: "cc:a"))
        XCTAssertEqual(try store.activeSessionCount(), 1)
    }

    func testActiveSessionCountIsZeroForAFreshStore() throws {
        let store = try Store.inMemory()
        XCTAssertEqual(try store.activeSessionCount(), 0)
    }

    func testActiveSessionCountDoesNotDoubleCountRepeatedEventsForTheSameSession() throws {
        let store = try Store.inMemory()

        try store.record(event(kind: .sessionStarted, sessionID: "cc:a"))
        try store.record(event(kind: .turnCompleted, sessionID: "cc:a"))
        try store.record(event(kind: .toolStarted, sessionID: "cc:a"))

        XCTAssertEqual(try store.activeSessionCount(), 1)
    }
}
