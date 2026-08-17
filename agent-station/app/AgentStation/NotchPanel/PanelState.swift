import Foundation

/// ARCHITECTURE.md §6.3. EXPANDED is the only state that accepts keyboard focus.
public enum PanelState: Sendable {
    case hidden
    case ambient    // ears only, 2px glow
    case compact    // pill, 3s auto-retract
    case expanded   // cards, actions, project groups
    case retracting // spring, 0.32s
}
