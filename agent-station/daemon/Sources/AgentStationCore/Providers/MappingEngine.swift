import Foundation

/// The `when`/`$.` grammar from a provider manifest (ARCHITECTURE.md §4.2) — a
/// deliberately boring expression language + JSONPath subset. Enough for field
/// extraction and branching, not a scripting language. Anything that needs real
/// logic is Class D and gets a signed binary plugin (`AgentProvider`), not a
/// bigger grammar here.
public enum MappingEngine {
    /// `field == 'literal'` clauses joined by `&&`. All clauses must hold.
    /// Fields are looked up as top-level keys of the raw provider payload.
    public static func evaluateWhen(_ expression: String, against object: [String: Any]) -> Bool {
        let clauses = expression.components(separatedBy: "&&").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { evaluateClause($0, against: object) }
    }

    private static func evaluateClause(_ clause: String, against object: [String: Any]) -> Bool {
        if clause.contains("!=") {
            return evaluateComparison(clause, splitOn: "!=", against: object, negate: true)
        } else if clause.contains("==") {
            return evaluateComparison(clause, splitOn: "==", against: object, negate: false)
        }
        return false
    }

    private static func evaluateComparison(_ clause: String, splitOn op: String, against object: [String: Any], negate: Bool) -> Bool {
        let parts = clause.components(separatedBy: op)
        guard parts.count == 2 else { return false }
        let field = parts[0].trimmingCharacters(in: .whitespaces)
        let literal = stringLiteral(parts[1].trimmingCharacters(in: .whitespaces))
        let actual = stringValue(object[field])
        let equal = actual == literal
        return negate ? !equal : equal
    }

    /// Strips a single layer of matching `'...'` quotes. Unquoted input is
    /// returned verbatim — the grammar has no other literal shape.
    private static func stringLiteral(_ token: String) -> String? {
        guard token.count >= 2, token.hasPrefix("'"), token.hasSuffix("'") else { return nil }
        return String(token.dropFirst().dropLast())
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case nil, is NSNull: return nil
        default: return String(describing: value!)
        }
    }

    /// Resolves a `$.field`, `$.['odd-key']`, or `$.field | truncate(N)`
    /// extraction template against the raw payload. Returns the input
    /// unchanged if it isn't a `$.`-prefixed template — manifests only ever
    /// pass templates here, but this keeps the function honest about intent.
    public static func resolveTemplate(_ template: String, against object: [String: Any]) -> String? {
        guard template.hasPrefix("$.") else { return template }
        let segments = template.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pathExpr = segments.first else { return nil }
        guard var value = resolvePath(pathExpr, against: object) else { return nil }
        for filter in segments.dropFirst() {
            value = applyFilter(filter, to: value)
        }
        return value
    }

    /// `$.foo` or `$.['foo-bar']` — single-segment field access. The manifests
    /// shipped today never chain segments; this is intentionally not a general
    /// JSONPath engine.
    private static func resolvePath(_ path: String, against object: [String: Any]) -> String? {
        var key = String(path.dropFirst(2)) // drop "$."
        if key.hasPrefix("['"), key.hasSuffix("']") {
            key = String(key.dropFirst(2).dropLast(2))
        }
        guard !key.isEmpty else { return nil }
        return stringValue(object[key])
    }

    private static func applyFilter(_ filter: String, to value: String) -> String {
        guard let openParen = filter.firstIndex(of: "("), filter.hasSuffix(")") else { return value }
        let name = filter[filter.startIndex..<openParen].trimmingCharacters(in: .whitespaces)
        let argsString = filter[filter.index(after: openParen)..<filter.index(before: filter.endIndex)]
        switch name {
        case "truncate":
            guard let n = Int(argsString.trimmingCharacters(in: .whitespaces)), n >= 0, value.count > n else { return value }
            return String(value.prefix(n))
        default:
            return value
        }
    }
}
