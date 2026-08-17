import Foundation

/// Declarative adapter. The test of §4: adding a provider must be a manifest
/// PR, not a core change. If a new provider forces you to touch the arbiter,
/// the store, or the panel — the abstraction leaked. Fix that, not the provider.
public struct ProviderManifest: Codable, Sendable {
    public struct Meta: Codable, Sendable {
        public var id: String
        public var displayName: String
        public var integrationClass: IntegrationClass
        public var maturity: Maturity
        public var icon: String
        public var detect: Detect
    }
    public struct Detect: Codable, Sendable {
        public var binary: String?
        public var configDir: String?
        public var bundleID: String?
    }
    public struct Install: Codable, Sendable {
        public enum Format: String, Codable, Sendable {
            case jsonMerge = "json-merge"
            case tomlRootKey = "toml-root-key"   // Codex: root keys BEFORE tables
            case jsonPatch = "json-patch"
        }
        public var configPath: String
        public var format: Format
        public var patch: String
        public var scope: InstallDiff.Scope
    }
    /// `when` is a deliberately boring expression grammar + JSONPath subset.
    /// Enough for field extraction and branching, not a scripting language.
    /// Anything needing real logic is Class D and gets a signed binary plugin.
    public struct Mapping: Codable, Sendable {
        public var when: String
        public var emit: EventKind
        public var title: String?
        public var detail: String?
        public var risk: Risk?
        public var decision: DecisionChannel?
    }
    public struct UsageSource: Codable, Sendable {
        public var source: String        // transcript | api | none
        public var pathGlob: String?
        public var tokenPath: String?
    }

    public var provider: Meta
    public var capabilities: ProviderCapabilities
    public var install: Install
    public var map: [Mapping]
    public var usage: UsageSource?
}
