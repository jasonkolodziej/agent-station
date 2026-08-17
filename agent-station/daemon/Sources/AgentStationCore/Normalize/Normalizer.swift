import Foundation

/// RawEvent -> [CanonicalEvent]. Unmapped provider events are NOT dropped
/// silently: they are recorded so `station doctor` can surface "provider
/// changed its schema" as a visible diagnostic rather than a mystery silence.
public struct Normalizer: Sendable {
    public struct UnmappedEvent: Sendable {
        public let provider: ProviderID
        public let providerEvent: String
        public let seenAt: Date
    }
    public init() {}
    public func normalize(_ raw: RawEvent, using registry: AdapterRegistry) async throws -> [CanonicalEvent] {
        // TODO(M0b)
        []
    }
}
