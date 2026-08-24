import Foundation

/// RawEvent -> [CanonicalEvent]. Unmapped provider events are NOT dropped
/// silently: they are recorded so `station doctor` can surface "provider
/// changed its schema" as a visible diagnostic rather than a mystery silence.
public struct Normalizer: Sendable {
    public struct UnmappedEvent: Sendable {
        public let provider: ProviderID
        public let providerEvent: String?
        public let seenAt: Date
        public let sampleJSON: String?
    }

    /// Either a mapped canonical event, or a record of why nothing matched.
    /// Kept as one result type so callers can't forget the unmapped path.
    public struct Result: Sendable {
        public let events: [CanonicalEvent]
        public let unmapped: UnmappedEvent?
    }

    public init() {}

    public func normalize(_ raw: RawEvent, using registry: AdapterRegistry) async throws -> Result {
        guard let manifest = await registry.manifest(for: raw.provider) else {
            return Result(events: [], unmapped: UnmappedEvent(
                provider: raw.provider, providerEvent: nil, seenAt: raw.receivedAt,
                sampleJSON: String(data: raw.raw, encoding: .utf8)))
        }
        return normalize(raw, manifest: manifest)
    }

    /// Pure, synchronous core — testable without spinning up an AdapterRegistry.
    public func normalize(_ raw: RawEvent, manifest: ProviderManifest) -> Result {
        let object = Self.decodeObject(raw.raw)
        let providerEventName = Self.providerEventName(from: object)

        guard let rule = manifest.map.first(where: { MappingEngine.evaluateWhen($0.when, against: object) }) else {
            return Result(events: [], unmapped: UnmappedEvent(
                provider: raw.provider, providerEvent: providerEventName, seenAt: raw.receivedAt,
                sampleJSON: String(data: raw.raw, encoding: .utf8)))
        }

        let payload = EventPayload(
            kind: Self.payloadKind(for: rule.emit),
            title: rule.title.flatMap { MappingEngine.resolveTemplate($0, against: object) },
            detail: rule.detail.flatMap { MappingEngine.resolveTemplate($0, against: object) },
            risk: rule.risk,
            decisionChannel: rule.decision ?? .none
        )

        // Best-effort session start: the true first-seen timestamp for this
        // session lives in the Store once session.started has been persisted.
        // This is per-event transport metadata, not the authoritative record.
        let session = SessionRef(
            id: Self.sessionID(provider: raw.provider, object: object),
            cwd: (object["cwd"] as? String) ?? raw.focus?.cwd ?? "",
            surface: (raw.focus?.isIDEHosted ?? false) ? .ide : .terminal,
            startedAt: raw.receivedAt
        )

        let event = CanonicalEvent(
            kind: rule.emit,
            ts: raw.receivedAt,
            provider: raw.provider,
            providerEvent: providerEventName,
            session: session,
            focus: raw.focus,
            payload: payload,
            replyToken: (rule.decision == .inline) ? Self.makeReplyToken() : nil
        )
        return Result(events: [event], unmapped: nil)
    }

    // MARK: - Helpers

    private static func decodeObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Claude Code and Gemini CLI name their event field `hook_event_name`;
    /// Codex's argv payload names it `type`. Neither is universal, so this is
    /// deliberately best-effort — it exists for the `provider_event` debug
    /// field, not for correctness of the mapping itself.
    private static func providerEventName(from object: [String: Any]) -> String? {
        (object["hook_event_name"] as? String) ?? (object["type"] as? String)
    }

    private static func payloadKind(for emit: EventKind) -> String? {
        switch emit {
        case .approvalRequested: return "approval"
        case .attentionRequired: return "idle"
        default: return nil
        }
    }

    /// Provider-scoped, stable for the run's lifetime (ARCHITECTURE.md §3,
    /// which shows `"id": "cc:6b1f…"` for Claude Code — the short prefix is
    /// part of the wire convention, not just a Claude Code fixture quirk).
    /// Falls back to a payload-derived placeholder when the provider doesn't
    /// expose a session id on every event (Codex's single notify call has
    /// none at all).
    private static func sessionID(provider: ProviderID, object: [String: Any]) -> String {
        let prefix = shortPrefix(for: provider)
        if let sid = object["session_id"] as? String {
            return "\(prefix):\(sid)"
        }
        return "\(prefix):unknown"
    }

    private static func shortPrefix(for provider: ProviderID) -> String {
        switch provider.rawValue {
        case "claude-code": return "cc"
        default: return provider.rawValue
        }
    }

    private static func makeReplyToken() -> String {
        "rt_\(UUID().uuidString.prefix(12))"
    }
}
