import ArgumentParser
import AgentStationCore

@main
struct Station: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Agent Station CLI",
        subcommands: [Tail.self, Doctor.self, Provider.self, Jump.self]
    )
}

/// The M0b deliverable: prove ingress works with no UI at all.
struct Tail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream canonical events as they arrive")
    @Flag var raw = false
    func run() async throws {}
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check wiring, permissions, unmapped provider events")
    func run() async throws {}
}

struct Provider: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage provider manifests",
        subcommands: [Validate.self, List.self])
    /// Applies + reverts the install patch against a scratch config dir.
    /// Step 4 of the "adding a new agent" checklist (ARCHITECTURE.md §15).
    struct Validate: AsyncParsableCommand {
        @Argument var id: String
        func run() async throws {}
    }
    struct List: AsyncParsableCommand { func run() async throws {} }
}

struct Jump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a session's owning window")
    @Argument var sessionID: String
    func run() async throws {}
}
