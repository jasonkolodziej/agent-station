import Foundation
import GRDB

/// SQLite (WAL) via GRDB. The daemon owns state; the panel, menu bar, and
/// VS Code extension are all clients that can die and re-hydrate.
public final class Store: Sendable {
    public static let retentionEvents: TimeInterval = 30 * 86400
    public static let retentionUsage: TimeInterval = 396 * 86400  // 13mo, YoY works
    public init(path: URL) throws { /* TODO(M0b) */ }
}
