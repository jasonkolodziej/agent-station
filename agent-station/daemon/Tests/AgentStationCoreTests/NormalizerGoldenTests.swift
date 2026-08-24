import Foundation
import XCTest
@testable import AgentStationCore

/// Golden-file driven: fixtures/<provider>/<name>.json is a verbatim raw
/// provider payload, fixtures/<provider>/<name>.expected.json is the
/// canonical event(s) it must normalize to (fixtures/README.md).
///
/// Comparison is a *subset* match: every key present in the expected file
/// must match the actual output, recursively. Fields the golden file omits
/// (id, ts, session.started_at, focus, ...) are not checked — several of them
/// (id, ts) are inherently nondeterministic and could never be golden-matched
/// exactly. This is what lets the fixtures assert "the mapping produced the
/// right event" without also pinning down clock/UUID values.
///
/// fixtures/ lives at the repo root, outside this SPM package, so it can't be
/// declared as a `resources:` copy target (Package.swift) — read directly off
/// disk via a path relative to this file instead.
final class NormalizerGoldenTests: XCTestCase {
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // NormalizerGoldenTests.swift -> AgentStationCoreTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> daemon/
            .deletingLastPathComponent()  // -> agent-station/ (repo root)
            .appending(path: "fixtures")
    }

    func testGoldenFixturesNormalizeAsExpected() async throws {
        let cases = try Self.discoverCases()
        XCTAssertFalse(cases.isEmpty, "no golden fixtures discovered under \(Self.fixturesRoot.path)")

        let registry = AdapterRegistry()
        for testCase in cases {
            let manifest = await registry.manifest(for: ProviderID(rawValue: testCase.provider))
            guard let manifest else {
                XCTFail("\(testCase): no manifest registered for provider '\(testCase.provider)' — add it to AdapterRegistry's built-ins")
                continue
            }

            let rawEvent = RawEvent(provider: ProviderID(rawValue: testCase.provider), raw: testCase.rawPayload)
            let result = Normalizer().normalize(rawEvent, manifest: manifest)

            let actualJSON = try Self.encodeAsJSONArray(result.events)
            let (ok, reason) = Self.isSubset(expected: testCase.expected, actual: actualJSON)
            XCTAssertTrue(ok, "\(testCase): \(reason ?? "mismatch")")
        }
    }

    // MARK: - Fixture discovery

    struct FixtureCase: CustomStringConvertible {
        let provider: String
        let name: String
        let rawPayload: Data
        let expected: Any // parsed JSON: [[String: Any]]

        var description: String { "\(provider)/\(name)" }
    }

    static func discoverCases() throws -> [FixtureCase] {
        let fm = FileManager.default
        guard let providerDirs = try? fm.contentsOfDirectory(at: fixturesRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var cases: [FixtureCase] = []
        for providerDir in providerDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? providerDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: providerDir, includingPropertiesForKeys: nil)) ?? []
            let expectedFiles = files.filter { $0.lastPathComponent.hasSuffix(".expected.json") }
            for expectedURL in expectedFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = String(expectedURL.lastPathComponent.dropLast(".expected.json".count))
                let rawURL = providerDir.appending(path: "\(name).json")
                guard fm.fileExists(atPath: rawURL.path) else { continue }
                let rawPayload = try Data(contentsOf: rawURL)
                let expectedData = try Data(contentsOf: expectedURL)
                let expected = try JSONSerialization.jsonObject(with: expectedData)
                cases.append(FixtureCase(provider: providerDir.lastPathComponent, name: name, rawPayload: rawPayload, expected: expected))
            }
        }
        return cases
    }

    // MARK: - Comparison

    static func encodeAsJSONArray(_ events: [CanonicalEvent]) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(events)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// True if every key/value in `expected` is present and equal in `actual`,
    /// recursively through nested objects and matched by-index through arrays.
    static func isSubset(expected: Any, actual: Any, path: String = "$") -> (Bool, String?) {
        switch (expected, actual) {
        case let (e as [String: Any], a as [String: Any]):
            for (key, evalue) in e {
                guard let avalue = a[key] else {
                    return (false, "\(path).\(key): missing in actual (expected \(evalue))")
                }
                let (ok, reason) = isSubset(expected: evalue, actual: avalue, path: "\(path).\(key)")
                if !ok { return (false, reason) }
            }
            return (true, nil)
        case let (e as [Any], a as [Any]):
            guard e.count <= a.count else {
                return (false, "\(path): expected \(e.count) element(s), actual has \(a.count)")
            }
            for (i, evalue) in e.enumerated() {
                let (ok, reason) = isSubset(expected: evalue, actual: a[i], path: "\(path)[\(i)]")
                if !ok { return (false, reason) }
            }
            return (true, nil)
        case let (e as String, a as String):
            return e == a ? (true, nil) : (false, "\(path): expected '\(e)', actual '\(a)'")
        case let (e as NSNumber, a as NSNumber):
            return e == a ? (true, nil) : (false, "\(path): expected \(e), actual \(a)")
        case (is NSNull, is NSNull):
            return (true, nil)
        default:
            return (false, "\(path): type mismatch, expected \(expected), actual \(actual)")
        }
    }
}
