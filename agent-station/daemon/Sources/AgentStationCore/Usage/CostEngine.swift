import Foundation

/// Two questions that get conflated (ARCHITECTURE.md §9):
///   "plan usage" — am I about to be rate limited?   (subscription windows)
///   "agent cost" — what did this burn in dollars?   (token accounting)
public enum WindowKind: String, Codable, Sendable {
    case rolling5h, weekly, monthlyCredit = "monthly_credit", copilotPremium = "copilot_premium"
}

/// RENDER THIS. A local-only estimate shows a hatched bar and "local estimate";
/// an authoritative reading shows solid. A false "you're fine" at 94% is the
/// single worst failure mode for this feature.
public enum Confidence: String, Codable, Sendable { case authoritative, localEstimate, unknown }

public struct WindowState: Codable, Sendable {
    public var provider: ProviderID
    public var kind: WindowKind
    public var used: Double
    public var limit: Double?
    public var confidence: Confidence
    public var resetsAt: Date?
    public var percent: Double? { limit.map { $0 > 0 ? used / $0 : 0 } }
}

public struct CostEngine: Sendable {
    /// Cache reads bill at a fraction of input price. A cost model that ignores
    /// cache tiers overstates agent spend by a large multiple, because agent
    /// harnesses re-send the same prefix every single turn.
    /// `priceRev` is stored per sample — retroactively re-pricing history is a
    /// bug, not a feature.
    public init() {}
}
