import Foundation

public struct ProviderID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// How much of the agent lifecycle a provider actually exposes.
/// See ARCHITECTURE.md §4.1 — these four classes are not cosmetic, they change
/// what the UI is allowed to offer.
public enum IntegrationClass: String, Codable, Sendable {
    case a  // rich lifecycle hooks, stdin/stdout JSON, CAN block
    case b  // single-event notifier, argv payload, CANNOT block
    case c  // session-file tailer, derived and laggy
    case d  // embedded: IDE extension host or in-process SDK
}

public enum Maturity: String, Codable, Sendable { case ga, beta, experimental }

/// Ship this in the settings UI. Honest degradation is a feature; a button that
/// silently does nothing is worse than no button.
public struct ProviderCapabilities: Codable, Sendable {
    public var integrationClass: IntegrationClass
    public var maturity: Maturity
    public var inlineApproval: Bool
    public var turnEvents: Bool
    public var toolEvents: Bool
    public var subagentEvents: Bool
    public var usageStream: Bool
    public var cancelRun: Bool
}

public struct ProbeResult: Sendable {
    public enum Wiring: Sendable { case notInstalled, installedUnwired, wired, wiredStale }
    public var binaryPath: URL?
    public var configPath: URL?
    public var wiring: Wiring
    public var version: String?
}

/// A reversible, reviewable change to a user's agent config. Never write
/// without showing this first (ARCHITECTURE.md §12).
public struct InstallDiff: Sendable {
    public var path: URL
    public var before: String
    public var after: String
    public var scope: Scope
    public enum Scope: Sendable { case user, project, managed }
}

public struct ReplyToken: RawRepresentable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum Decision: Sendable {
    case allow(hookStdout: String?)
    case deny(reason: String)
}

public enum ProviderError: Error, Sendable {
    /// Thrown by Class B/C providers for `decide`. Callers must handle this by
    /// falling back to jump-to-session, never by pretending success.
    case unsupported(capability: String)
    case notInstalled
    case configParseFailed(path: URL, underlying: String)
    case wiringRefused(reason: String)
}

public struct RawEvent: Sendable {
    public let provider: ProviderID
    public let receivedAt: Date
    public let focus: FocusContext?
    public let raw: Data           // verbatim provider payload from the shim
    public let truncated: Bool
}

public struct UsageSample: Sendable {
    public var sessionID: String
    public var model: String
    public var inputTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var billingMode: BillingMode
    public var priceRev: String
}

/// Copilot-routed models are neither a subscription window nor an API bill —
/// they are premium requests. Added per ARCHITECTURE.md §17 Q8.
public enum BillingMode: String, Codable, Sendable {
    case subscription, api, credit, copilotPremium = "copilot_premium"
}

/// The extensibility contract. Most providers never implement this directly —
/// they ship a manifest (§4.2) handled by `ManifestProvider`. This protocol is
/// the escape hatch for providers whose behaviour cannot be declared.
public protocol AgentProvider: Sendable {
    static var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    func probe() async -> ProbeResult

    /// Must be idempotent and reversible. Called on install and on repair.
    func install(shim: URL) async throws -> InstallDiff
    func uninstall() async throws

    /// Zero or more canonical events. Returning [] is legitimate — many raw
    /// events are noise we deliberately drop.
    func normalize(_ raw: RawEvent) throws -> [CanonicalEvent]

    /// Throws .unsupported for Class B/C.
    func decide(_ token: ReplyToken, _ decision: Decision) async throws

    func sampleUsage() async throws -> [UsageSample]
}

public extension AgentProvider {
    func decide(_ token: ReplyToken, _ decision: Decision) async throws {
        throw ProviderError.unsupported(capability: "inlineApproval")
    }
    func sampleUsage() async throws -> [UsageSample] { [] }
}
