import Foundation

/// "Jump to session" (ARCHITECTURE.md §8). The hardest UX bet in the product —
/// if this is unreliable, Agent Station is a prettier notification.
///
/// Strategies are tried in order and each one degrades to the next. The last
/// one always works, so the button is never dead.
public enum FocusStrategy: String, Sendable, CaseIterable {
    case ideURIHandler      // cursor://, vscode:// -> extension focuses window
    case itermSelectSession // AppleScript: exact pane
    case tmuxSelectPane     // focus terminal app, then tmux select-pane
    case accessibilityRaise // AXRaise on matching AXWindow
    case activateApp        // NSRunningApplication.activate — right app, wrong tab
}

public struct FocusResult: Sendable {
    public let strategy: FocusStrategy
    public let succeeded: Bool
    public let fellBackFrom: [FocusStrategy]
}

public actor FocusRouter {
    public init() {}

    public func jump(to focus: FocusContext) async -> FocusResult {
        // TODO(M2) — instrument every attempt. Strategy success rate per
        // terminal is the metric that tells you whether F4 is real.
        FocusResult(strategy: .activateApp, succeeded: false, fellBackFrom: [])
    }

    /// Accessibility permission is requested LAZILY, on first jump, with an
    /// explanation — never at first launch. The app stays useful without it,
    /// degraded to .activateApp.
    public func hasAccessibilityPermission() -> Bool { false }
}
