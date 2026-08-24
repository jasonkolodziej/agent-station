# Agent Station — System Architecture

**Status:** Draft v0.2 · Design review (v0.2: VS Code promoted to baseline; milestones reordered)
**Scope:** macOS 14+ (Apple Silicon and Intel), notch and non-notch displays
**One-line:** A local-first macOS daemon + notch UI that replaces per-tool agent notifications with a single, arbitrated attention surface — and a pluggable adapter layer so any coding agent can be added without touching the core.

---

## 0. Platform reality check (read this first)

macOS does **not** expose a Dynamic Island API. There is no `DynamicIslandActivity`, no `ActivityKit` equivalent, no vendor extension point. Every shipping "Mac Dynamic Island" app — NotchNook, Alcove, Boring Notch, DynamicLake, Notchy — implements the same trick:

> A borderless, transparent `NSPanel` subclass, positioned flush to the top-center of the active screen at `CGShieldingWindowLevel` (above the menu bar), rendering a custom `Shape` with concave Bézier "ears" that visually fuse with the physical notch cutout.

Consequences that drive the architecture:

| Reality | Architectural consequence |
|---|---|
| It's a window, not a system surface | It can be occluded, lost on display change, and dies with the app. It **cannot** be the source of truth for state. |
| No OS-level activity registry | We own arbitration. Two agents finishing simultaneously is our problem to solve, not the system's. |
| Works on non-notch displays too | Geometry must be a computed layout, not a hardcoded notch rect. Fall back to a floating pill. |
| Menu-bar-level window ≠ background service | The UI process must be separable from the event ingestion process. |

**This is the central design decision: the notch is a *view*, not the app.** Everything else follows from that.

---

## 1. Requirements

### 1.1 Functional (derived from target feature set)

| ID | Feature | Requirement |
|---|---|---|
| F1 | Dynamic agent island | Live status for in-flight runs, rendered in/around the notch |
| F2 | Approval alerts | Surface permission prompts; approve/deny inline **where the agent protocol permits** |
| F3 | Grouped by project | Sessions aggregate under a stable project identity, not a cwd string |
| F4 | Jump to session | One click returns focus to the exact terminal pane or IDE window that owns the run |
| F5 | Plan usage | Rolling-window and weekly quota consumption per provider |
| F6 | Track agent costs | Token → dollar attribution, per session / project / day |
| F7 | Mac keep awake | Battery-aware sleep suppression while runs are in flight |
| F8 | Local first | No network dependency for core function; telemetry off by default |
| F9 | Signed in-app updates | EdDSA-signed, notarized, delta-capable |
| **F11a** | **VS Code baseline (stable API)** | **Window identity, focus routing, notification suppression, integrated-terminal session binding. Ships to Marketplace.** |
| **F11b** | **VS Code session bridge (proposed API)** | **Two-way: observe Agent Sessions; contribute CLI sessions back into the Agent Sessions view. Insiders / VSIX only — see §7.5.** |
| F10 | Multi-agent CLI coverage | Claude Code, Codex, OpenClaw GA; OpenCode, Gemini CLI, Qwen Code, Hermes beta |

**Priority note (revised v0.2):** F11 precedes F10. Rationale in §7.0. In short — VS Code is the platform layer beneath Cursor, Devin, Copilot, and the model picker, so one Class D adapter covers more surface than the entire CLI provider matrix; and the CLI-fleet niche is already occupied (§7.6).

### 1.2 Non-functional

- **Ingress latency budget: ≤ 10 ms p99.** Several agents run hooks *synchronously in the agent loop* — Gemini CLI explicitly blocks the loop until matching hooks return, and Claude Code's `UserPromptSubmit`/`PreToolUse` hooks gate the turn. A slow hook is a slow agent. This is the hardest constraint in the system.
- **Fail-open, always.** If the daemon is down, the shim exits `0` in under 1 ms. Agent Station must never wedge someone's coding session.
- **Idle cost: < 1% of one core, < 60 MB RSS.** It's a background utility competing with `Notchy`-class apps benchmarked at that level.
- **Zero required network egress** except update checks and license validation.
- **Adding a provider = a manifest, not a release.** See §6.

### 1.3 Explicit non-goals (v1)

- Running or orchestrating agents. Agent Station observes and routes attention; it does not spawn work.
- Cloud sync of session state.
- Windows/Linux. (The transport and adapter layers are portable; the presentation layer is not.)

---

## 2. Component architecture

```
┌───────────────────────────────────────────────────────────────────────────┐
│ AGENT PROCESSES (untrusted, out-of-process, arbitrary lifetimes)          │
│                                                                           │
│  Claude Code    Codex CLI    Cursor      Gemini CLI   OpenCode   Hermes   │
│  30 hook evts   notify[1]    hooks.json  hooks        adapter    adapter  │
└──────┬──────────────┬────────────┬────────────┬───────────┬───────────────┘
       │ stdin JSON   │ argv JSON  │ stdio JSON │ stdin JSON│ log tail / PTY
       ▼              ▼            ▼            ▼           ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  agentstation-hook          INGRESS SHIM (Rust/Swift static, ~2 MB)       │
│  • reads payload, stamps provider id + focus context from own env         │
│  • writes JSONL to UDS, optionally reads one decision frame back          │
│  • 1 ms fail-open path if socket absent                                   │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ AF_UNIX  ~/Library/.../agentstation.sock
                               │ JSON Lines, length-prefixed, SO_PEERCRED
                               ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  agentstationd            CORE DAEMON (LaunchAgent, always-on)            │
│                                                                           │
│  ┌────────────┐  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Adapter    │→ │ Normalizer  │→ │ Session       │→│ Attention        │  │
│  │ Registry   │  │ (→ canonical│  │ Store         │  │ Arbiter          │  │
│  │ (manifests)│  │  events)    │  │ (SQLite/WAL)  │  │ (priority queue) │  │
│  └────────────┘  └─────────────┘  └──────┬────────┘  └────────┬─────────┘  │
│                                          │                    │            │
│  ┌────────────┐  ┌─────────────┐  ┌──────▼────────┐  ┌────────▼─────────┐  │
│  │ Usage &    │  │ Keep-Awake  │  │ Project       │  │ Focus Router     │  │
│  │ Cost Engine│  │ Service     │  │ Resolver      │  │ (AX + deeplinks) │  │
│  └────────────┘  └─────────────┘  └───────────────┘  └──────────────────┘  │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ same UDS, subscribe channel (server-push)
        ┌──────────────────────┼──────────────────────┬─────────────────────┐
        ▼                      ▼                      ▼                     ▼
┌───────────────┐   ┌────────────────┐   ┌─────────────────┐   ┌──────────────┐
│ AgentStation  │   │ Menu bar item  │   │ VS Code ext     │   │ CLI          │
│ .app (SwiftUI)│   │ (fallback UI)  │   │ (Copilot-style) │   │ `station`    │
│ NOTCH PANEL   │   │                │   │ + Cursor fork   │   │              │
└───────────────┘   └────────────────┘   └─────────────────┘   └──────────────┘
```

### Why a daemon and not one app

1. **Hooks fire from processes we don't control, at times the UI may not be running.** A `LaunchAgent` with `KeepAlive` is the only always-on receiver.
2. **The notch panel is fragile by nature** — display reconfiguration, Stage Manager, screen lock, full-screen video. It must be restartable without losing session state.
3. **VS Code windows are ephemeral.** The extension is a client, not a store.
4. **Separation lets the shim stay tiny.** Ingress latency is the hard constraint; the shim links no UI frameworks.

---

## 3. Canonical event model

Every provider collapses into this vocabulary. Adapters translate; the core never knows what "SubagentStop" is.

```jsonc
{
  "v": 1,
  "event": "attention.required",       // see enum below
  "ts": "2026-08-13T18:41:02.884Z",
  "provider": "claude-code",
  "provider_event": "Notification",    // preserved verbatim for debugging
  "session": {
    "id": "cc:6b1f…",                  // provider-scoped, stable for run lifetime
    "project_id": "prj_9f2a…",         // resolved, see §5
    "cwd": "/Users/j/src/meridian",
    "surface": "terminal",             // terminal | ide | cloud | headless
    "model": "claude-opus-5",
    "started_at": "2026-08-13T18:12:00Z"
  },
  "focus": {                            // captured ONCE at session.started — see §8
    "term_program": "iTerm.app",
    "term_session_id": "w0t2p1:2F3C…",
    "tmux_pane": "%14",
    "host_pid": 44182,
    "ide_window_id": null,
    "workspace_uri": null
  },
  "payload": {
    "kind": "approval",                // approval | input | elicitation | idle
    "title": "Run shell command",
    "detail": "rm -rf ./dist",
    "risk": "high",
    "decision_channel": "inline",      // inline | terminal_only | none
    "deadline_ms": 8000
  },
  "reply_token": "rt_3f19…"            // present iff decision_channel == "inline"
}
```

### 3.1 Event enum

| Canonical event | Meaning | Drives |
|---|---|---|
| `session.started` | New run detected | Island appears; focus context captured |
| `session.ended` | Run torn down | Island retires; keep-awake released |
| `turn.started` | Model turn begins | Progress spinner |
| `turn.completed` | Model turn ends | **Primary "done" alert** |
| `attention.required` | Agent is blocked on a human | **Highest-priority alert** |
| `approval.requested` | Blocking permission prompt | Inline approve/deny if supported |
| `approval.resolved` | Prompt answered (by us or in-terminal) | Dismiss alert |
| `tool.started` / `tool.completed` | Optional granularity | Ambient activity text |
| `usage.sampled` | Token/cost delta | Usage + cost engine |
| `error.raised` | Turn failed | Error state |

Deliberately small. Resist adding a canonical event for anything only one provider emits — put it in `payload` and let the UI ignore it.

---

## 4. Provider adapter SPI — the extensibility contract

This is the part that determines whether "other agent coders can be easily integrated" is true or aspirational.

### 4.1 Four integration classes

Providers differ enormously in what they expose. Classify honestly rather than pretending uniformity:

| Class | Mechanism | Fidelity | Can block? | Examples |
|---|---|---|---|---|
| **A — Rich lifecycle hooks** | JSON on stdin, JSON + exit code on stdout | Full | **Yes** | Claude Code (~30 events incl. `Notification`, `Stop`, `SubagentStop`, `PermissionRequest`, `PreToolUse`); Gemini CLI (`BeforeTool`, `AfterTool`, `Notification`, `AfterAgent`); Cursor (`hooks.json`: `beforeSubmitPrompt`, `afterFileEdit`, `beforeShellExecution`, `afterAgentResponse`, `stop`) |
| **B — Single-event notifier** | Program invoked with JSON as an **argv argument** | Completion only | **No** | Codex CLI `notify` — one event (`agent-turn-complete`), no matcher, no return channel |
| **C — Session-file tailer** | Watch JSONL transcripts / state dirs | Derived, laggy | No | Fallback for providers with no hook surface; also how usage/cost is reconstructed |
| **D — Embedded/in-process** | IDE extension host or SDK callbacks | Full, bidirectional | Yes | VS Code / Cursor extension; Agent SDK in-process callbacks |

The UI must **render capability honestly**. If a Codex session is blocked on a permission prompt, we cannot offer an inline Approve button — the correct affordance is "Jump to terminal," and the manifest says so. Pretending otherwise produces a button that silently does nothing, which is worse than no button.

### 4.2 The manifest

Adding a provider is a declarative manifest plus, at most, a small mapping expression. No core recompile.

```toml
# ~/Library/Application Support/AgentStation/providers/qwen-code.toml
[provider]
id            = "qwen-code"
display_name  = "Qwen Code"
class         = "A"
maturity       = "beta"
icon          = "qwen.svg"
detect         = { binary = "qwen", config_dir = "~/.qwen" }

[capabilities]
inline_approval   = true
turn_events       = true
tool_events       = true
subagent_events   = false
usage_stream      = false     # cost reconstructed from transcripts instead
cancel_run        = false

[install]
# How we wire ourselves in. Reversible, and diffed before write.
config_path = "~/.qwen/settings.json"
format      = "json-merge"
patch = '''
{ "hooks": { "Notification": [{ "hooks": [
    { "type": "command", "command": "${SHIM} --provider qwen-code" }]}],
             "AfterAgent":   [{ "hooks": [
    { "type": "command", "command": "${SHIM} --provider qwen-code" }]}] } }
'''

[[map]]
when      = "hook_event_name == 'Notification' && matcher == 'permission_prompt'"
emit      = "approval.requested"
title     = "$.message"
risk      = "high"
decision  = "inline"

[[map]]
when      = "hook_event_name == 'AfterAgent'"
emit      = "turn.completed"
title     = "$.last_message | truncate(80)"

[usage]
source     = "transcript"
path_glob  = "~/.qwen/sessions/**/*.jsonl"
token_path = "$.usage"
```

`when`/`$.` are a deliberately boring expression + JSONPath subset — enough for field extraction and branching, not a scripting language. Anything that needs real logic is Class D and gets a signed binary plugin.

An optional `[notifications]` section — `keys = [...]`, VS Code settings keys
— feeds §7.1 step 1 ("turn the source off") for a provider that *also* ships
its own VS Code extension with its own notification UI. Qwen Code here is
CLI-only, so it has none. Never populate this from a guess: a wrong key
either does nothing or silently changes something unrelated, worse than
leaving it empty until someone verifies the real key against the extension's
own `package.json` contribution.

### 4.3 Native plugin interface (escape hatch)

```swift
public protocol AgentProvider: Sendable {
    static var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    /// Detect installation + current wiring state.
    func probe() async -> ProbeResult

    /// Idempotently install/remove our hook wiring. Must be reversible.
    func install(shim: URL) async throws -> InstallDiff
    func uninstall() async throws

    /// Translate a raw provider payload into zero or more canonical events.
    func normalize(_ raw: RawEvent) throws -> [CanonicalEvent]

    /// Answer a blocking prompt. Throws .unsupported for Class B/C.
    func decide(_ token: ReplyToken, _ decision: Decision) async throws

    /// Usage/cost sampling, if the provider exposes it.
    func sampleUsage() async throws -> [UsageSample]
}
```

**Provider coverage matrix (v1 target):**

| Provider | Class | Inline approve | Turn done | Usage | Status |
|---|---|---|---|---|---|
| Claude Code | A | ✅ | ✅ | ✅ `/usage` + transcripts | GA |
| Cursor | A + D | ✅ | ✅ | ⚠️ partial | GA |
| Codex CLI | B | ❌ (jump only) | ✅ | ⚠️ transcript-derived | GA |
| OpenClaw | A | ✅ | ✅ | ✅ gateway | GA |
| Gemini CLI | A | ✅ | ✅ | ⚠️ | Beta |
| OpenCode | A/C | ⚠️ | ✅ | ⚠️ | Beta |
| Qwen Code | A | ⚠️ | ✅ | ❌ | Beta |
| Hermes | C | ❌ | ✅ | ❌ | Beta |

Ship the matrix in the app's provider settings screen. Honesty about degradation is a feature.

---

## 5. Project resolution (F3 — "Grouped by project")

Grouping on `cwd` breaks the moment someone uses a git worktree, a monorepo package dir, or `/tmp` scratch checkouts. Resolution order:

1. `git rev-parse --show-toplevel` → canonical worktree root
2. `git config --get remote.origin.url` → normalized (strip protocol, `.git`, credentials)
3. `project_id = sha256(normalized_remote)[..16]` — worktrees of the same repo **collapse into one project**, with worktree as a sub-grouping
4. No remote → `sha256(realpath(toplevel))`
5. No git → `sha256(realpath(cwd))`, flagged `ephemeral: true` and hidden from the project list after 24 h idle

Cache in SQLite keyed by `realpath(cwd)`; invalidate on `CwdChanged`-class events. Never shell out to git on the ingress path — resolve asynchronously in the daemon after the event is already accepted.

---

## 6. Attention arbitration (F1 — the island itself)

One notch, N agents. The arbiter is the piece that makes this better than N separate notification banners.

### 6.1 Priority ladder

```
P0  approval.requested (risk=high, deadline approaching)   → expand, hold, sound
P1  approval.requested / attention.required                → expand, hold
P2  error.raised                                           → expand 4s, then badge
P3  turn.completed on a foreground-relevant project        → compact pill 3s
P4  turn.completed elsewhere                               → badge increment only
P5  tool/progress activity                                 → ambient ear glyph
```

### 6.2 Coalescing rules

- Only **one** live activity is expanded at a time. Losers stack into a right-ear counter (`⌘3`).
- Same-session events within 400 ms coalesce (agents emit bursts).
- Repeat `turn.completed` for a session already acknowledged → suppressed entirely.
- If the user is *already focused on the owning window*, downgrade two levels. Nobody needs a notch alert about the terminal they're staring at. Detect via frontmost app + AX focused window vs. `focus` context.

### 6.3 Panel state machine

```
        ┌──────────┐  event P4/P5   ┌───────────┐
        │  HIDDEN  │───────────────▶│  AMBIENT  │  (ears only, 2px glow)
        └────┬─────┘                └─────┬─────┘
             │ hover / P3                 │ hover
             ▼                            ▼
        ┌──────────┐  P0/P1/P2      ┌───────────┐
        │ COMPACT  │◀──────────────▶│ EXPANDED  │  (cards, actions, project groups)
        └────┬─────┘                └─────┬─────┘
             │ 3s timeout                 │ esc / click-away / decision
             ▼                            ▼
        ┌──────────┐                ┌───────────┐
        │  HIDDEN  │◀───────────────│  RETRACT  │  (spring, 0.32s)
        └──────────┘                └───────────┘
```

`EXPANDED` is the only state that accepts keyboard focus, and it must **not** steal focus from the editor — use `NSPanel` with `becomesKeyOnlyIfNeeded = true` and `.nonactivatingPanel`. A notch UI that pulls focus mid-typing will be uninstalled within a day.

### 6.4 Geometry

```swift
struct NotchGeometry {
    // Hardware notch = the difference between screen frame and safeAreaInsets.top
    static func notchRect(for screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0 else { return nil }   // non-notch Mac
        let auxTop = screen.auxiliaryTopLeftArea            // menu bar left region
        let auxTopRight = screen.auxiliaryTopRightArea
        // notch width = full width − (left aux + right aux)
        …
    }
}
```

Non-notch and external displays: render a floating pill at top-center with the same state machine and the same `NotchShape` minus the concave ears. **One layout engine, two silhouettes** — do not fork the view hierarchy.

---

## 7. VS Code as the baseline platform (F11) — *promoted ahead of F10*

### 7.0 Why VS Code first

Three arguments, in ascending order of force.

**1. One integration, many models.** VS Code lets you <cite>choose from dozens of models across OpenAI, Anthropic, Google, and more, including bring-your-own-key and self-hosted models</cite>. A single Class D adapter therefore rides along with every model a user switches to, with no per-model work.

*But be precise about what this does and doesn't buy:* the picker gives you N **models** under **one harness**. Copilot agent mode with Claude selected behaves like Copilot, not like Claude Code — different system prompt, different tool set, different permission model, different cost profile. So VS Code coverage is not a substitute for the F10 provider matrix; it's an orthogonal, higher-leverage axis. Claim the leverage, don't overclaim the coverage.

**2. VS Code is the substrate, not a peer.** Cursor is a VS Code fork and loads the same extension. Windsurf, Devin's editor surfaces, Kiro, and most enterprise IDE-agent deployments descend from the same base. Building the CLI adapters first means building N bespoke integrations to reach a fraction of the users one extension reaches.

**3. The decisive one — VS Code already shipped the aggregator.** The Agent Sessions view <cite>gives you one place to manage all your agents, whether they're running locally or in the cloud — see which agents are running, their status, and jump between sessions with a click</cite>. Microsoft explicitly calls this making VS Code <cite>"mission control" for orchestrating all your agents</cite>. There is also a session status indicator in the title bar with <cite>badges for unread messages and in-progress sessions</cite>.

This reframes the product. **Aggregation is not the differentiator — it's table stakes that two other parties already ship.** What VS Code's Agent Sessions view structurally cannot do is reach you when VS Code isn't frontmost, or when the session lives in iTerm, or when you're in Figma. Agent Station's defensible claim is *attention outside the editor, with reliable routing back into it.* That claim is only legible if you sit next to VS Code rather than pretending it doesn't exist.

### 7.1 What is and isn't possible — stated plainly

You **cannot** intercept another extension's `window.showInformationMessage`, and you cannot suppress an OS notification another process posted. There is no VS Code API for that, and there shouldn't be.

What actually works is a three-part substitution:

1. **Turn the source off.** The extension writes the agent extension's own notification settings to `false` in user settings (keys are provider-specific and resolved from the manifest, so this survives upstream renames). Diffed and shown to the user before write; one-click revert.
2. **Take over the signal via hooks.** The same event that would have raised the banner now arrives at the daemon through the Class A hook, and the island renders it with project context, cost, and an action.
3. **Own the return path.** The extension registers a URI handler so the island's "Jump to session" lands in the correct window (§8).

### 7.2 Extension responsibilities

```
agent-station-vscode/
├── extension.ts
│   ├── registerWindowIdentity()   // workspace folders, window id, PID → daemon
│   ├── registerUriHandler()       // vscode://…/session/<id> → reveal + focus
│   ├── StatusBarItem              // live run count, click → expand island
│   ├── ChatParticipant "@station" // phase 2: query sessions/costs from chat
│   └── LanguageModelTool          // phase 2: expose station state to agents
├── daemon-client.ts               // UDS client, reconnecting, backpressure-safe
└── settings-manager.ts            // provider notification suppression + revert
```

**Window identity** is the critical piece and is registered on activate:

```ts
await client.send({
  event: "ide.window.registered",
  ide: vscode.env.appName,                    // "Visual Studio Code" | "Cursor"
  window_id: vscode.env.sessionId,
  pid: process.ppid,
  workspace_roots: vscode.workspace.workspaceFolders?.map(f => f.uri.fsPath),
  uri_scheme: vscode.env.uriScheme            // "vscode" | "cursor" | "vscode-insiders"
});
```

The daemon now maps `cwd → open IDE window`, which is what makes F4 work for IDE-hosted sessions.

**This is one connection, not a one-shot request.** The extension sends
`ide.window.registered` as the first message and then keeps the socket open
for as long as the window is: `ide.window.focus` on focus change,
`ide.terminal.open` / `ide.terminal.close` for integrated-terminal binding
(§7.4's cheap half), and `ide.window.unregistered` on dispose. The daemon
folds the same connection into the canonical-event broadcast once
`ide.window.registered` is seen, so the extension's status bar gets live
events on the connection it already has open rather than a second one.
Everything here is keyed off the connection's fd server-side — if a window
disappears without sending `ide.window.unregistered` (crash, force-quit),
the closed connection itself is the cleanup signal, not a timeout.

`window_id` must be re-sent on every reconnect, not just once at activation:
the daemon's window registry lives only in live connection state, so a
daemon restart mid-session drops it, and a message sent before the socket's
`connect` event fires is silently lost. `daemonClient.ts` exposes `onConnect`
for exactly this — callers that need the daemon to know their current state
hook it there, not at extension activation.

**The daemon pushes back on the same connection, too.** After every batch of
canonical events it processes, it recomputes and broadcasts
`{event: "ui.counts", running, needs_attention}` to every registered window —
`running` from the session table's `ended_at IS NULL` count, `needs_attention`
from the attention arbiter's live, unacknowledged, blocking/attention/error
activities. That drives the status bar's badge without a second poll or
connection. The extension can also ask
`{event: "query.suppression_rules"}` and gets back
`{event: "suppression_rules", rules: [{provider, keys}]}` built from whichever
registered provider manifests declare `[notifications] keys = [...]` — today
that's none, deliberately: a wrong VS Code settings key either does nothing or
silently changes something unrelated, and guessing one is worse than leaving
the list empty until a manifest ships a verified key.

**Chat participant (phase 2)** follows the Copilot pattern exactly — `vscode.chat.createChatParticipant('agent-station.station', handler)`, plus a `LanguageModelTool` so *other* agents can ask Agent Station "what's running and what has it cost me today." That inverts the relationship nicely: the station becomes queryable context, not just a notifier.

### 7.3 Cursor

Cursor is a VS Code fork and loads the same extension. It additionally supports `hooks.json` and can load Claude Code–format third-party hooks, so it is covered by both Class A and Class D. Prefer the hook path for events (it fires for CLI sessions too) and the extension path for focus routing.

### 7.4 The bidirectional bridge (F11b) — the actual differentiated idea

The obvious direction is VS Code → notch. The interesting direction is the reverse.

`chatSessionsProvider` lets an extension contribute sessions *into* the Agent Sessions view. So Agent Station can register your **Claude Code session running in iTerm** and your **Codex run in tmux** as first-class entries in VS Code's own session list — alongside Copilot and cloud agents — with status, unread badges, and click-to-jump.

```
   iTerm: claude ──┐
   tmux:  codex  ──┼──▶ agentstationd ──┬──▶ Notch island (attention, outside editor)
   Ghostty: gemini─┘                    │
                                        └──▶ ChatSessionItemProvider
                                             └──▶ VS Code Agent Sessions view
                                                  (terminal agents appear as
                                                   third-party agent sessions)
```

Neither VS Code (doesn't see your terminal) nor the CLI-fleet apps (don't see your editor) close this loop. This is the strongest version of "integrate like Copilot does" — not mimicking Copilot's UI, but occupying the same extension points Copilot occupies, in both directions.

### 7.5 ⚠️ The risk that governs the whole reorder

**`chatSessionsProvider` is a proposed API.** VS Code's docs state proposed APIs are <cite>subject to change, only available in Insiders distribution and cannot be used in published extensions</cite>. `vsce` enforces this at publish time — it <cite>throws an error when the manifest declares `enabledApiProposals`</cite>. The "blessed" escape hatch is an allowlist in VS Code's own `product.json` under `extensionEnabledApiProposals`, which only Microsoft controls.

Concretely: **F11b cannot ship on the Marketplace today.** Distribution is VSIX + Insiders + a `--enable-proposed-api` launch flag, which is a hostile install path for a consumer utility.

Consequences for the plan:

| | Ships to Marketplace | Depends on | Do it |
|---|---|---|---|
| **F11a** — window identity, URI handler, focus routing, notification suppression, integrated-terminal binding, status bar | ✅ stable API | `env.sessionId`, `window.registerUriHandler`, `workspace.workspaceFolders`, terminal shell integration | **M1. Now.** |
| **F11b** — observe/contribute Agent Sessions | ❌ proposed | `chatSessionsProvider` | Spike now, ship behind Insiders; re-evaluate each VS Code release |
| Chat participant `@station` + `LanguageModelTool` | ✅ stable | `chat.createChatParticipant`, `lm.registerTool` | M4 |

**Therefore the very first task in the reordered plan is a two-day spike, not a build:** *what can a stable-API extension actually observe about another extension's agent session?* If the honest answer is "essentially nothing," F11a is still worth shipping — focus routing and suppression are the load-bearing parts — but the bridge narrative in §7.4 becomes an Insiders-only preview and the roadmap must say so out loud. Find that out in week one.

### 7.6 Competitive position — why not race on F10

AgentMax already ships the CLI-fleet board: one board for every agent on your Mac, see what they're doing, jump to the one that needs you, know what they cost, keep the Mac awake. That is close to a superset of F1–F8 as originally scoped.

So the original M3-heavy plan pointed at the one axis where a shipping competitor is ahead, while leaving unclaimed the axis where nobody is: the editor. Restated positioning:

| | Aggregates CLI agents | Aggregates IDE agents | Surfaces outside the editor | Routes focus both ways |
|---|---|---|---|---|
| VS Code Agent Sessions | partial (Copilot CLI) | ✅ | ❌ | ❌ |
| AgentMax | ✅ | ❌ | ✅ (menu bar) | one-way |
| **Agent Station** | ✅ (F10, later) | ✅ (F11a, first) | ✅ (notch) | ✅ (F11b) |

The notch is the *form factor*, not the moat. The moat is being the only thing that spans terminal and editor in both directions. F10 is a fast-follow once the bridge exists — and by then the manifest system (§4.2) makes each provider cheap.

---

## 8. Focus routing (F4 — "Jump to session")

**The load-bearing insight: focus context must be captured at `session.started`, from the hook process's own environment. It is unrecoverable later.** Once the turn completes, nothing in the payload tells you which of your eleven iTerm panes owns it.

The shim reads, on first event for a session:

| Signal | Source | Used for |
|---|---|---|
| `TERM_PROGRAM` | env | Which terminal app |
| `ITERM_SESSION_ID` | env | iTerm2 window/tab/pane triple |
| `TERM_SESSION_ID` | env | Apple Terminal |
| `WEZTERM_PANE`, `KITTY_WINDOW_ID`, `GHOSTTY_RESOURCES_DIR` | env | Others |
| `TMUX`, `TMUX_PANE` | env | tmux pane, needs two-stage focus |
| `getppid()` chain | proc | Owning process, host PID |
| `VSCODE_PID`, `VSCODE_CWD`, `TERM_PROGRAM=vscode` | env | Integrated terminal → IDE window |

Routing strategy, in order:

1. **IDE-hosted session** → `open "cursor://file/<path>"` or the registered URI handler; extension calls `window.showTextDocument` + `commands.executeCommand('workbench.action.focusActiveEditorGroup')`.
2. **iTerm2** → AppleScript `select` on the session id (exact pane, not just app).
3. **tmux inside any terminal** → focus terminal app, then `tmux select-pane -t %14`.
4. **Other terminals** → Accessibility API (`AXRaise` on the matching `AXWindow`) using window title heuristics + PID.
5. **Fallback** → `NSRunningApplication(processIdentifier:).activate()`. Right app, wrong tab, but never a dead button.

Requires Accessibility permission. Request it *lazily*, on first jump attempt, with an explanation — not at first launch. Every permission maps to exactly one capability and is skippable; the app must remain useful without it (degraded to strategy 5).

---

## 9. Usage and cost engine (F5, F6)

Two distinct questions that get conflated:

- **"Plan usage"** — am I about to be rate-limited? Subscription windows.
- **"Agent costs"** — what did this burn in dollars? Token accounting.

### 9.1 Plan usage

Claude subscriptions run a **5-hour rolling window plus a weekly cap**, and the pool is shared across Claude Code, Claude apps, and Cowork — so local-only accounting systematically under-reports. Claude Code's own `/usage` is explicitly computed from local session history on that machine.

Design accordingly:

- Model it as `WindowState { provider, window_kind: rolling5h|weekly|monthly_credit, used, limit, confidence }`.
- **Render confidence in the UI.** A local-only estimate shows a hatched bar and "local estimate"; an authoritative reading shows solid. Never present a derived number as fact — a false "you're fine" at 94% is the single worst failure mode for this feature.
- Providers with a real usage API get polled (respecting rate limits); everything else is reconstructed from transcript token fields.
- Threshold alerts at 70/85/95% fire as P2, once per window per threshold.

### 9.2 Cost

```sql
CREATE TABLE usage_sample (
  id            INTEGER PRIMARY KEY,
  session_id    TEXT NOT NULL,
  project_id    TEXT NOT NULL,
  provider      TEXT NOT NULL,
  model         TEXT NOT NULL,
  ts            INTEGER NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_write   INTEGER NOT NULL DEFAULT 0,
  cache_read    INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  billing_mode  TEXT NOT NULL,          -- subscription | api | credit
  price_rev     TEXT NOT NULL           -- pricing table revision used
);
CREATE INDEX ix_usage_project_ts ON usage_sample(project_id, ts);
```

Notes that matter for correctness:

- **Cache reads are billed at a fraction of input price** — a cost model that ignores cache tiers will overstate agent spend by a large multiple, because agent harnesses re-send the same prefix (system prompt, tool defs, project instruction files) every turn.
- Store `price_rev` alongside each sample. Pricing changes; retroactively re-pricing history is a bug, not a feature.
- On subscription billing, show **both** "dollar-equivalent" and "quota consumed," and label the former as notional. Users on a Max plan are not spending that money.
- Pricing tables ship as a signed, versioned JSON asset updated independently of the app binary.

---

## 10. Keep-awake service (F7)

`IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleSystemSleep` — not `caffeinate(8)` as a subprocess, which is fragile and leaks on crash.

Guardrails (this is the "battery-aware" part):

```swift
struct KeepAwakePolicy {
    var enabledOnBattery: Bool = false          // default: AC only
    var minBatteryPercent: Int = 30             // hard floor, releases below
    var maxAssertionDuration: TimeInterval = 4 * 3600
    var releaseWhenLidClosed: Bool = true       // clamshell → release, always
    var releaseOnLowPowerMode: Bool = true
}
```

- Assertion is **reference-counted against active sessions**, taken on first `session.started`, released on last `session.ended` — never held globally.
- Watch `IOPSNotificationCreateRunLoopSource` for power-source and capacity changes; re-evaluate on every transition.
- Display sleep is *not* prevented by default (`PreventUserIdleSystemSleep`, not `PreventUserIdleDisplaySleep`). The machine keeps working; the screen goes dark. That's what people actually want and it roughly halves the battery cost.
- Always show the assertion state in the menu bar. An invisible thing holding your Mac awake is a support ticket generator.

---

## 11. Persistence

SQLite (WAL) via GRDB, at `~/Library/Application Support/AgentStation/store.sqlite`.

```
project(id, name, remote_url, root_path, last_seen_at, pinned)
session(id, provider, project_id, cwd, surface, model, started_at, ended_at, state)
focus_context(session_id, term_program, term_session_id, tmux_pane, host_pid,
              ide_window_id, workspace_uri)
event(id, session_id, kind, ts, payload_json)          -- ring-buffered, 30d default
approval(id, session_id, requested_at, resolved_at, decision, decided_by, risk)
usage_sample(…)                                         -- §9.2
window_state(provider, window_kind, used, limit, confidence, resets_at)
```

Retention: events 30 days, usage samples 13 months (so year-over-year works), everything user-purgeable per project. Local-first means the user can delete it and nothing phones home about it.

---

## 12. Transport and security

- **AF_UNIX** at `~/Library/Application Support/AgentStation/agentstation.sock`, mode `0600`. Not TCP — no port, no localhost attack surface, and peer identity comes free.
- **JSON Lines**, newline-delimited, 256 KB frame cap. Oversized payloads (a transcript blob) are truncated at the shim with a `truncated: true` flag.
- **Peer validation**: `LOCAL_PEERCRED` for uid match. Code-signature validation of the connecting binary for the *decision* channel only (approving a `rm -rf` is a privileged act; reporting a completion is not).
- **Reply tokens** are single-use, session-scoped, and expire with the prompt deadline.
- **Hook wiring is diffed and consented.** Agent Station writes to `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.cursor/hooks.json`, `~/.gemini/settings.json`. Every write shows a diff, is reversible, and never touches project-level config the user shares with their team — user scope only, unless explicitly opted in. (Note the Codex TOML gotcha: `notify` is a root key and must be written *above* any `[table]`, or the file silently breaks.)
- **Sandbox posture:** the main app is sandboxed; the daemon is not (it needs arbitrary-path config writes and AX). Both hardened-runtime + notarized. Document this asymmetry — reviewers will ask.

**Threat note worth writing down:** the shim is invoked by whatever the agent's config says. If an attacker can write a user's `hooks.json`, they already have code execution as that user; Agent Station doesn't widen that. But the daemon must treat all inbound payloads as hostile input — no `eval`, no path traversal from `cwd`, no shelling out with unescaped payload fields.

---

## 13. Updates (F9)

Sparkle 2 with **EdDSA (ed25519) signatures**, appcast over HTTPS with certificate pinning, delta updates, and staged rollout percentages.

- Signing key lives in a hardware token / CI secret, never in the repo.
- Update check is the only default network egress; it sends version + OS + arch, nothing else. Say so in the UI.
- The daemon and the shim are updated *together with* the app and version-negotiate on connect (`v` field, §3). A stale shim talking to a new daemon must degrade, not crash — the shim's fail-open path covers this.
- Provider manifests update out-of-band on a separate signed channel, so "Qwen Code changed their hook schema" is a manifest push, not a release.

---

## 14. Failure modes and the honest answers

| Failure | Behavior |
|---|---|
| Daemon not running | Shim exits 0 in <1 ms. Agent unaffected. Events lost. Menu bar shows disconnected. |
| Notch panel crashes | Daemon unaffected; panel relaunched by app; state re-hydrated from store. |
| Display reconfiguration | Panel tears down and re-lays-out on `NSApplication.didChangeScreenParametersNotification`. |
| Provider changes hook schema | Manifest `map` rules stop matching → event lands as `provider_event` with no canonical mapping → logged, surfaced in a "unmapped events" diagnostic. Fails visible, not silent. |
| Two Macs, same account | v1: no sync. Usage numbers are per-machine and labeled as such. |
| Approval deadline expires | Prompt auto-dismisses in the island; the agent's own terminal prompt remains authoritative. We never auto-approve. |
| Full-screen app / Do Not Disturb | Respect Focus modes. P0 approvals may optionally break through (opt-in, off by default). |

**We never auto-approve anything.** Not on a timeout, not on a rule, not for "low risk." An app that can click Approve on `rm -rf` while you're at lunch is a liability, and the moment it exists it becomes the feature people ask you to make smarter. Draw that line at v1 and hold it.

---

## 15. Adding a new agent — the actual checklist

The test of §4. Adding "Qwen Code" should be:

1. Write `providers/qwen-code.toml` (§4.2) — classify, declare capabilities, define install patch, map 3–6 events.
2. Add an icon asset.
3. Write a golden-file test: fixture payloads in → expected canonical events out.
4. Run `station provider validate qwen-code` — checks install patch applies and reverts cleanly against a scratch config dir.
5. Ship the manifest on the signed manifest channel. Mark `maturity = "beta"`.

**No core code changes. No app release.** If a new provider requires touching the arbiter, the store, or the panel, the abstraction leaked and that's the bug to fix — not the provider.

---

## 16. Milestones

**Revised v0.2 — VS Code moved from M5 to M1; CLI provider matrix moved from M3 to M6.**

| Phase | Deliverable | Proves / kills |
|---|---|---|
| **M0a** | ✅ **Closed 2026-08-24.** Spike: what a *stable-API* extension can observe about another extension's agent session; whether `chatSessionsProvider` accepts externally-owned sessions. Results in [ADR-0004](./docs/adr/0004-vscode-first.md#spike-results). | **Confirmed the reorder (§7.5).** Stable API: no observability of foreign sessions — confirms F11a's hook-based approach is the only path. Proposed API: externally-owned/read-only sessions are supported by design (`ChatSessionItemController`, `requestHandler: undefined`), but `registerChatSessionItemProvider` is now deprecated in favor of that controller API — retarget F11b accordingly. Insiders install cost is 4 steps, 2 needing a terminal — still an Insiders-only preview, not a Marketplace path. Live Insiders round-trip of Q2 still needed before M5 build work. |
| **M0b** | Shim + daemon + SQLite + `station tail`. Claude Code hooks only, no UI. | Ingress latency budget (≤10 ms p99) is achievable |
| **M1** | **VS Code extension (F11a):** window identity, URI handler, notification suppression, integrated-terminal session binding, status bar. Marketplace-publishable. | The stated origin problem — replacing the monolithic VS Code banner — is actually solved |
| **M2** | Focus router (F4) + project resolver (F3), IDE path first, terminal path second | The hardest UX bet. If "jump to session" is unreliable the product is a prettier notification |
| **M3** | Notch panel: AMBIENT/COMPACT/EXPANDED, driven by VS Code sessions only | The panel doesn't steal focus and survives display reconfiguration |
| **M4** | Approvals (F2) inline where supported; chat participant `@station` + `LanguageModelTool` | Decision channel, reply tokens, signature validation |
| **M5** | **Bridge (F11b)** behind Insiders flag: CLI sessions contributed into Agent Sessions view | The differentiated claim in §7.4 — gated on M0a |
| **M6** | Codex (Class B) + remaining CLI matrix via manifests (F10) | Manifest abstraction holds across integration classes A/B/C |
| **M7** | Usage + cost (F5, F6), keep-awake (F7), Sparkle (F9), manifest channel | Adding a provider is a manifest, not a release |

Two things now fail fast instead of late: the proposed-API dependency (M0a, week one) and focus-routing reliability (M2, week three). Both were month-four discoveries in v0.1.

One consequence worth accepting deliberately: **the notch is no longer the first thing built.** M1–M2 ship value through the VS Code status bar and the menu bar. That is uncomfortable for a product named after its form factor, but the alternative is polishing a panel before knowing whether there's anything reliable to put in it.

---

## 17. Open questions

1. **Does the notch have enough room for multi-agent state?** Expanded height is generous, but the compact pill is ~200×32 pt. Test with 5 concurrent sessions before committing to the pill as the primary state.
2. **Is inline approval a good idea at all?** It's the highest-value feature and the highest-risk one. Consider shipping approvals as *jump-with-context* first and adding inline decisions only after the focus router is proven.
3. **Sessions that outlive their terminal.** `claude -p` in CI, cloud agents, detached tmux. Currently modeled as `surface: headless` with no focus route. Needs a real answer if headless usage grows.
4. **Menu bar vs. notch as the primary surface.** The notch is the differentiator; the menu bar is the reliable fallback. Build both from the same view models and let usage data decide which is default.
5. **Non-notch Macs and external displays** are probably a majority of sessions. The pill must not feel like a consolation prize.
6. **Does `chatSessionsProvider` finalize, and when?** The entire F11b narrative rides on it. Track the proposal in VS Code's api-finalization milestones; if it stalls for two release cycles, cut the bridge from the pitch and lead with focus routing instead.
7. **Does Microsoft ship notch/OS-level surfacing itself?** The Agent Sessions title-bar indicator with in-progress badges is one step from a background presence. If VS Code grows an out-of-editor notifier, Agent Station's remaining moat is the terminal half and the routing. Worth watching each release.
8. **Copilot's model picker changes the cost model.** When a user runs Claude via Copilot on a Copilot subscription, the token spend is neither an Anthropic subscription window nor an API bill — it's Copilot premium requests. §9 currently has no `billing_mode` for that. Add `copilot_premium` before M4.

---

## References

- Claude Code hooks (lifecycle events, JSON stdin, exit-code semantics, settings layering) — code.claude.com/docs, and the Agent SDK in-process callback equivalent
- Codex CLI `notify` (single `agent-turn-complete` event, argv payload, no return channel; root-key-before-tables TOML constraint) — openai/codex, community write-ups
- Cursor hooks (`hooks.json`, stdio JSON both directions, project/user/team/enterprise scopes, third-party Claude Code hook compatibility) — cursor.com/docs/hooks
- Gemini CLI hooks (v0.26.0+, synchronous in the agent loop, strict-JSON-on-stdout rule, extension-bundled hooks) — geminicli.com/docs/hooks, Google Developers Blog
- VS Code Chat Participant + Language Model + Language Model Tools APIs — code.visualstudio.com/api/extension-guides/ai/chat
- VS Code Agent Sessions view and `chatSessionsProvider` proposed API — code.visualstudio.com/docs/chat/chat-sessions; "A Unified Experience for all Coding Agents," VS Code blog, Nov 2025
- VS Code model selection across providers — code.visualstudio.com/features/agents
- Proposed API distribution constraints (Insiders-only, `vsce` publish rejection, `product.json` allowlist) — code.visualstudio.com/api/advanced-topics/using-proposed-api; microsoft/vscode-vsce; microsoft/vscode Extension API process wiki
- AgentMax — agentmax.dev (competitive reference for the CLI-fleet niche)
- macOS notch panel technique (`NSPanel` at `CGShieldingWindowLevel`, concave-Bézier `NotchShape`) — as implemented by NotchNook, Alcove, Boring Notch, Notchy
- Claude plan limits (5-hour rolling window + weekly cap, pooled across surfaces, `/usage` computed from local session history) — Anthropic docs and usage-tooling write-ups
