import Foundation

/// Stable project identity (ARCHITECTURE.md §5). Grouping on cwd breaks on git
/// worktrees, monorepo package dirs, and /tmp checkouts.
///
/// NEVER call this on the ingress path — resolve asynchronously after the event
/// is already accepted. Shelling out to git inside the 10ms budget is how you
/// slow down someone's agent.
public actor ProjectResolver {
    private var cache: [String: String] = [:]   // realpath(cwd) -> project_id

    public init() {}

    public func resolve(cwd: String) async -> String {
        if let hit = cache[cwd] { return hit }
        // 1. git rev-parse --show-toplevel
        // 2. git config --get remote.origin.url, normalised
        // 3. sha256(normalised_remote)[..16]  <- worktrees collapse into one project
        // 4. no remote  -> sha256(realpath(toplevel))
        // 5. no git     -> sha256(realpath(cwd)), ephemeral: true
        // TODO(M2)
        return ""
    }
    public func invalidate(cwd: String) { cache[cwd] = nil }
}
