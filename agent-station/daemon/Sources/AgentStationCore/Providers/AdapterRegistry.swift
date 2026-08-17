import Foundation

/// Loads manifests from disk + built-in binary plugins, and routes RawEvents
/// to the right normalizer.
public actor AdapterRegistry {
    private var manifests: [ProviderID: ProviderManifest] = [:]
    private var native: [ProviderID: any AgentProvider] = [:]

    public init() {}

    public func loadManifests(from dir: URL) throws {
        // TODO(M6): parse *.toml, validate against schema/provider-manifest.schema.json
    }
    public func register(_ provider: any AgentProvider) {
        native[type(of: provider).id] = provider
    }
    public func provider(for id: ProviderID) -> (any AgentProvider)? { native[id] }
    public func capabilities(for id: ProviderID) -> ProviderCapabilities? {
        native[id]?.capabilities ?? manifests[id]?.capabilities
    }
}
