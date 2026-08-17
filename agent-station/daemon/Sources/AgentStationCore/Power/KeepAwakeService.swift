import Foundation
import IOKit.pwr_mgt

/// Battery-aware sleep suppression (ARCHITECTURE.md §10).
///
/// Uses IOPMAssertion directly rather than spawning `caffeinate(8)`, which
/// leaks a child process if we crash. The assertion is reference-counted
/// against active sessions — never held globally.
public struct KeepAwakePolicy: Codable, Sendable {
    public var enabledOnBattery: Bool = false          // default: AC only
    public var minBatteryPercent: Int = 30             // hard floor
    public var maxAssertionDuration: TimeInterval = 4 * 3600
    public var releaseWhenLidClosed: Bool = true       // clamshell: always
    public var releaseOnLowPowerMode: Bool = true
    /// Note we prevent SYSTEM idle sleep, not DISPLAY sleep. The machine keeps
    /// working, the screen goes dark — roughly halves the battery cost and is
    /// what people actually want.
    public var preventDisplaySleep: Bool = false
}

public actor KeepAwakeService {
    public private(set) var policy = KeepAwakePolicy()
    private var assertionID: IOPMAssertionID = 0
    private var activeSessions: Set<String> = []
    private var heldSince: Date?

    public init() {}

    public func sessionStarted(_ id: String) { activeSessions.insert(id); reevaluate() }
    public func sessionEnded(_ id: String)   { activeSessions.remove(id);  reevaluate() }
    public func powerStateChanged()          { reevaluate() }
    public func setPolicy(_ p: KeepAwakePolicy) { policy = p; reevaluate() }

    public var isHeld: Bool { assertionID != 0 }

    // MARK: -

    private func reevaluate() {
        shouldHold() ? acquire() : release()
    }

    private func shouldHold() -> Bool {
        guard !activeSessions.isEmpty else { return false }
        if let since = heldSince, Date().timeIntervalSince(since) > policy.maxAssertionDuration {
            return false
        }
        let power = PowerState.current()
        if policy.releaseWhenLidClosed && power.lidClosed { return false }
        if policy.releaseOnLowPowerMode && power.lowPowerMode { return false }
        if power.onBattery {
            guard policy.enabledOnBattery else { return false }
            guard power.percentRemaining > policy.minBatteryPercent else { return false }
        }
        return true
    }

    private func acquire() {
        guard assertionID == 0 else { return }
        let type = policy.preventDisplaySleep
            ? kIOPMAssertionTypeNoDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Agent Station: \(activeSessions.count) agent run(s) in flight" as CFString,
            &id
        )
        if ok == kIOReturnSuccess { assertionID = id; heldSince = Date() }
    }

    private func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        heldSince = nil
    }
}

struct PowerState: Sendable {
    var onBattery: Bool
    var percentRemaining: Int
    var lowPowerMode: Bool
    var lidClosed: Bool

    static func current() -> PowerState {
        // TODO(M7): IOPSCopyPowerSourcesInfo + IOPSGetPowerSourceDescription;
        // lid state via IOPMrootDomain "AppleClamshellState".
        // Subscribe with IOPSNotificationCreateRunLoopSource and call
        // KeepAwakeService.powerStateChanged() on every transition.
        PowerState(onBattery: false, percentRemaining: 100,
                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                   lidClosed: false)
    }
}
