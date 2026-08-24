import Foundation

/// Loads manifests from disk + built-in binary plugins, and routes RawEvents
/// to the right normalizer.
public actor AdapterRegistry {
    private var manifests: [ProviderID: ProviderManifest] = [:]
    private var native: [ProviderID: any AgentProvider] = [:]

    /// M0b seeds the two reference manifests in-memory (mirrors
    /// providers/claude-code.toml and providers/codex.toml byte-for-byte in
    /// intent) so the normalize pipeline and `station tail` work end to end
    /// without a UI. Parsing arbitrary *.toml from disk — the actual "adding a
    /// provider is a manifest, not a release" promise — is M6 scope; see
    /// docs/adr/0004-vscode-first.md and ARCHITECTURE.md §15/§16.
    public init(seedBuiltInManifests: Bool = true) {
        if seedBuiltInManifests {
            for m in Self.builtInManifests {
                manifests[ProviderID(rawValue: m.provider.id)] = m
            }
        }
    }

    public func loadManifests(from dir: URL) throws {
        // TODO(M6): parse *.toml, validate against schema/provider-manifest.schema.json
    }

    public func register(_ manifest: ProviderManifest) {
        manifests[ProviderID(rawValue: manifest.provider.id)] = manifest
    }

    public func register(_ provider: any AgentProvider) {
        native[type(of: provider).id] = provider
    }

    public func provider(for id: ProviderID) -> (any AgentProvider)? { native[id] }

    public func manifest(for id: ProviderID) -> ProviderManifest? { manifests[id] }

    public func allManifests() -> [ProviderManifest] {
        manifests.values.sorted { $0.provider.id < $1.provider.id }
    }

    public func capabilities(for id: ProviderID) -> ProviderCapabilities? {
        native[id]?.capabilities ?? manifests[id]?.capabilities
    }

    // MARK: - Built-in reference manifests (M0b bootstrap only, see init above)

    private static let builtInManifests: [ProviderManifest] = [claudeCode, codex]

    private static let claudeCode = ProviderManifest(
        provider: .init(
            id: "claude-code", displayName: "Claude Code", integrationClass: .a, maturity: .ga,
            icon: "claude-code.svg", detect: .init(binary: "claude", configDir: "~/.claude", bundleID: nil)),
        capabilities: .init(
            integrationClass: .a, maturity: .ga, inlineApproval: true, turnEvents: true,
            toolEvents: true, subagentEvents: true, usageStream: true, cancelRun: false),
        install: .init(
            configPath: "~/.claude/settings.json", format: .jsonMerge, patch: "", scope: .user),
        map: [
            .init(when: "hook_event_name == 'Notification' && matcher == 'permission_prompt'",
                  emit: .approvalRequested, title: "$.message", detail: nil, risk: .high, decision: .inline),
            .init(when: "hook_event_name == 'Notification' && matcher == 'idle_prompt'",
                  emit: .attentionRequired, title: "$.message", detail: nil, risk: .low, decision: .terminalOnly),
            .init(when: "hook_event_name == 'Stop'", emit: .turnCompleted, title: nil, detail: nil, risk: nil, decision: nil),
            // A Stop hook registered inside a subagent is delivered as SubagentStop.
            // Not equivalent to the turn ending — alerting on it is the fastest way
            // to make the island feel like spam.
            .init(when: "hook_event_name == 'SubagentStop'", emit: .toolCompleted, title: nil, detail: nil, risk: nil, decision: nil),
            .init(when: "hook_event_name == 'StopFailure'", emit: .errorRaised, title: nil, detail: nil, risk: nil, decision: nil),
            .init(when: "hook_event_name == 'SessionStart'", emit: .sessionStarted, title: nil, detail: nil, risk: nil, decision: nil),
            .init(when: "hook_event_name == 'SessionEnd'", emit: .sessionEnded, title: nil, detail: nil, risk: nil, decision: nil),
        ],
        usage: .init(source: "transcript", pathGlob: "~/.claude/projects/**/*.jsonl", tokenPath: "$.message.usage")
    )

    private static let codex = ProviderManifest(
        provider: .init(
            id: "codex", displayName: "Codex CLI", integrationClass: .b, maturity: .ga,
            icon: "codex.svg", detect: .init(binary: "codex", configDir: "~/.codex", bundleID: nil)),
        capabilities: .init(
            integrationClass: .b, maturity: .ga, inlineApproval: false, turnEvents: true,
            toolEvents: false, subagentEvents: false, usageStream: false, cancelRun: false),
        install: .init(
            configPath: "~/.codex/config.toml", format: .tomlRootKey, patch: "", scope: .user),
        map: [
            .init(when: "type == 'agent-turn-complete'", emit: .turnCompleted,
                  title: "$.['last-assistant-message'] | truncate(80)", detail: nil, risk: nil,
                  decision: DecisionChannel.none),
        ],
        usage: .init(source: "transcript", pathGlob: "~/.codex/sessions/**/*.jsonl", tokenPath: nil)
    )
}
