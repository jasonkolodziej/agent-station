import Foundation
import XCTest
@testable import AgentStationCore

/// Non-fixture-driven Normalizer behavior: truncated payloads and unknown
/// providers. NormalizerGoldenTests covers the manifest-mapping happy path.
final class NormalizerTests: XCTestCase {
    private func claudeCodeManifest() async -> ProviderManifest {
        let registry = AdapterRegistry()
        return await registry.manifest(for: "claude-code")!
    }

    func testTruncatedPayloadAlwaysRoutesToUnmappedEvenWhenItHappensToParse() async {
        let manifest = await claudeCodeManifest()
        // Valid, mappable JSON — but flagged truncated by the shim because it
        // hit the 256KB cap. The mapping must not be trusted just because
        // this particular cut landed on a clean boundary.
        let payload = Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8)
        let raw = RawEvent(provider: "claude-code", raw: payload, truncated: true)

        let result = Normalizer().normalize(raw, manifest: manifest)

        XCTAssertTrue(result.events.isEmpty, "a truncated payload must never produce a canonical event")
        guard let unmapped = result.unmapped else {
            return XCTFail("expected an unmapped record for a truncated payload")
        }
        XCTAssertTrue(unmapped.providerEvent?.hasSuffix("[truncated]") ?? false, "unmapped.providerEvent: \(unmapped.providerEvent ?? "nil")")
    }

    func testTruncatedPayloadThatFailsToParseStillMarksTruncatedNotJustUnknown() async {
        let manifest = await claudeCodeManifest()
        // Truncated mid-object: invalid JSON, decodeObject will come back empty.
        let payload = Data(#"{"hook_event_name":"Notification","matc"#.utf8)
        let raw = RawEvent(provider: "claude-code", raw: payload, truncated: true)

        let result = Normalizer().normalize(raw, manifest: manifest)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.unmapped?.providerEvent, "unknown [truncated]")
    }

    func testNonTruncatedUnmappedEventDoesNotCarryTheTruncatedMarker() async {
        let manifest = await claudeCodeManifest()
        let payload = Data(#"{"hook_event_name":"SomeFutureHookWeDontMapYet"}"#.utf8)
        let raw = RawEvent(provider: "claude-code", raw: payload, truncated: false)

        let result = Normalizer().normalize(raw, manifest: manifest)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.unmapped?.providerEvent, "SomeFutureHookWeDontMapYet")
    }

    func testUnknownProviderRoutesToUnmappedWithNoManifestLookup() async {
        let registry = AdapterRegistry()
        let raw = RawEvent(provider: "some-provider-with-no-manifest", raw: Data("{}".utf8))

        let result = try! await Normalizer().normalize(raw, using: registry)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.unmapped?.provider.rawValue, "some-provider-with-no-manifest")
    }
}
