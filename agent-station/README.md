# Agent Station

A local-first macOS daemon and notch UI that replaces per-tool agent notifications
with a single arbitrated attention surface — and routes you back to the exact
terminal pane or editor window that needs you.

**Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md). Read §7 and §16 before writing code.**

---

## Current milestone: M1 — VS Code extension (F11a)

- **M0a (spike) — closed 2026-08-24.** Results in
  [`docs/adr/0004-vscode-first.md`](./docs/adr/0004-vscode-first.md#spike-results):
  the stable API exposes no observability of another extension's agent
  session, which confirms the hook-based approach is the only path for
  F11a; the reorder holds.
- **M0b (shim + daemon + SQLite + `station tail`) — done.** Verified against
  the real shim binary, not just unit tests: `make test` covers the shim
  latency guard and the daemon's normalize/store/arbiter pipeline; a live
  trace (shim → daemon → `station tail`) confirmed the ingress path end to
  end.
- **M1 (this milestone):** window identity, URI handler, notification
  suppression, integrated-terminal session binding, status bar — all stable
  API, Marketplace-publishable. See ARCHITECTURE.md §7.2.
  - ✅ Window identity, focus, and terminal binding — daemon-side
    `WindowRegistry` plus the corrected `daemonClient.ts`/`windowIdentity.ts`.
    Verified live against the real daemon.
  - ✅ Status bar has something to show: `ui.counts` is computed from the
    session table and the attention arbiter and pushed on every event batch.
  - ✅ Notification-suppression *wiring* — `query.suppression_rules` /
    `suppression_rules` round-trips correctly, but returns no rules yet: no
    provider manifest has a verified VS Code settings key to suppress. See
    §4.2's `[notifications]` section.
  - ⬜ Not yet done: running the extension in an actual VS Code Extension
    Development Host; Marketplace listing readiness (icon, publisher
    metadata) hasn't been reviewed.

`make spike` still exists to re-run the M0a questions if VS Code's proposed
API surface changes — see open question 6 in ARCHITECTURE.md §17.

---

## What this is not

- **Not an agent orchestrator.** Agent Station observes and routes attention. It
  does not spawn work.
- **Not an aggregator, primarily.** VS Code's Agent Sessions view and AgentMax
  both ship aggregation. The differentiator is reaching you *outside* the editor
  and routing you reliably back in — spanning terminal and IDE in both
  directions, which neither of those does.
- **Not something that auto-approves.** See [ADR-0005](./docs/adr/0005-never-auto-approve.md).

---

## Layout

```
shim/          Rust, zero deps. Invoked by every agent hook. <=10ms p99, fail-open.
daemon/        Swift. Owns all state. LaunchAgent, always-on.
  Sources/AgentStationCore/
    Events/      Canonical event vocabulary (§3)
    Providers/   The extensibility SPI + manifest model (§4)
    Attention/   Arbiter: one notch, N agents (§6). No AppKit — unit-testable.
    Focus/       Jump-to-session (§8). The hardest UX bet.
    Project/     Stable project identity across worktrees (§5)
    Usage/       Plan windows and cost, with confidence levels (§9)
    Power/       Battery-aware keep-awake (§10)
app/           SwiftUI. NSPanel notch surface. A VIEW, not the app (ADR-0001).
extension/     TypeScript. VS Code + Cursor. src/proposed/ never ships.
providers/     Declarative manifests. Adding an agent = a PR here, not a release.
fixtures/      Golden files: raw provider payload in -> canonical events out.
schema/        JSON Schema for the wire format.
docs/adr/      Why things are the way they are, and what would reverse each one.
```

## Data flow

```
agent hook ──▶ agentstation-hook ──UDS/JSONL──▶ agentstationd ──▶ notch panel
                (splices raw bytes,              (normalize, store,      menu bar
                 captures focus ctx,              arbitrate, route)      VS Code ext
                 never parses payload)                                   station CLI
```

Two things worth internalising before touching the code:

**The shim never parses the payload.** It splices raw bytes into an envelope.
Gemini CLI blocks its agent loop on hooks; Claude Code's gate the turn. Parsing
belongs in the daemon, which is not on the hot path. [ADR-0003](./docs/adr/0003-zero-dep-shim.md)

**Focus context is captured once, at session start, from the shim's own
environment.** By the time a turn completes, nothing identifies which of eleven
iTerm panes owns the run. Get this wrong and "Jump to session" is unbuildable.

## Getting started

```bash
make bootstrap     # toolchain check + deps
make spike         # M0a — start here
make test          # includes the shim latency guard (a release blocker)
```

## Adding a provider

Should be a manifest, not a code change. If it isn't, the abstraction leaked and
that's the bug to fix.

1. `providers/<id>.toml` — classify (A/B/C/D), declare capabilities, define the
   install patch, map 3–6 events
2. Icon asset
3. Golden fixtures in `fixtures/<id>/`
4. `station provider validate <id>` — applies and reverts the patch against a
   scratch config dir
5. Ship on the signed manifest channel, `maturity = "beta"`

**Probe capabilities, never guess them.** A wrong `inline_approval` flag
produces an Approve button that silently does nothing — worse than no button.
Codex is the reference case: one event, argv payload, no return channel, so the
correct affordance is Jump, not Approve.

## Non-negotiables

| | |
|---|---|
| Shim fail-open | Every error path exits 0. We never wedge someone's session. |
| Latency guard | `shim/tests/latency.rs` failing is a release blocker. |
| Config writes | Always diffed, always reversible, user scope only. Project configs are shared with a team — don't touch them. |
| No auto-approve | Schema-enforced. No `auto` value for `decided_by`. |
| Usage confidence | Local estimates render as estimates. A false "you're fine" at 94% is the worst failure this product can have. |
| Panel focus | `.nonactivatingPanel`. Stealing focus mid-typing gets you uninstalled. |
| `enabledApiProposals` | Never in the shipping manifest. CI enforces this. |
