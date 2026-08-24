import Foundation
import XCTest
@testable import AgentStationCore

final class WindowRegistryTests: XCTestCase {
    private func identity(windowID: String = "win-1", roots: [String] = ["/Users/j/src/meridian"]) -> WindowIdentity {
        WindowIdentity(ide: "Visual Studio Code", windowID: windowID, pid: 1234, workspaceRoots: roots, uriScheme: "vscode")
    }

    func testRegisterThenLookupByExactCwd() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity())

        let found = registry.window(forCwd: "/Users/j/src/meridian")
        XCTAssertEqual(found?.windowID, "win-1")
    }

    func testLookupByCwdMatchesSubdirectoryOfWorkspaceRoot() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity(roots: ["/Users/j/src/monorepo"]))

        // A session running in a package inside the open workspace root.
        let found = registry.window(forCwd: "/Users/j/src/monorepo/packages/api")
        XCTAssertEqual(found?.windowID, "win-1")
    }

    func testLookupByCwdDoesNotFalsePositiveOnPrefixCollision() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity(roots: ["/Users/j/src/meridian"]))

        // "/Users/j/src/meridian-two" has "meridian" as a string prefix but is
        // not a subdirectory of the registered root.
        let found = registry.window(forCwd: "/Users/j/src/meridian-two")
        XCTAssertNil(found)
    }

    func testUnregisterRemovesTheWindowAndItsTerminalBindings() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity())
        registry.bindTerminal(pid: 999, toWindowFD: 10)
        XCTAssertNotNil(registry.window(forTerminalPID: 999))

        registry.unregister(fd: 10)

        XCTAssertNil(registry.window(forCwd: "/Users/j/src/meridian"))
        XCTAssertNil(registry.window(forTerminalPID: 999))
    }

    func testTerminalBindingResolvesToOwningWindow() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity(windowID: "win-a"))
        registry.register(fd: 11, identity: identity(windowID: "win-b", roots: ["/other"]))
        registry.bindTerminal(pid: 555, toWindowFD: 11)

        XCTAssertEqual(registry.window(forTerminalPID: 555)?.windowID, "win-b")
    }

    func testUnbindTerminalRemovesTheBindingWithoutTouchingTheWindow() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity())
        registry.bindTerminal(pid: 42, toWindowFD: 10)

        registry.unbindTerminal(pid: 42)

        XCTAssertNil(registry.window(forTerminalPID: 42))
        XCTAssertNotNil(registry.window(forCwd: "/Users/j/src/meridian"))
    }

    func testFocusTrackingReflectsSetFocused() {
        let registry = WindowRegistry()
        let win = identity()
        registry.register(fd: 10, identity: win)
        XCTAssertFalse(registry.isFocused(win))

        registry.setFocused(fd: 10, focused: true)
        XCTAssertTrue(registry.isFocused(win))

        registry.setFocused(fd: 10, focused: false)
        XCTAssertFalse(registry.isFocused(win))
    }

    func testAllReturnsEveryRegisteredWindow() {
        let registry = WindowRegistry()
        registry.register(fd: 10, identity: identity(windowID: "win-a"))
        registry.register(fd: 11, identity: identity(windowID: "win-b", roots: ["/other"]))

        let ids = Set(registry.all().map(\.windowID))
        XCTAssertEqual(ids, ["win-a", "win-b"])
    }
}
