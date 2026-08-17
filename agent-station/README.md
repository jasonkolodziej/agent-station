# Agent Station

A local-first macOS daemon and notch UI that replaces per-tool agent notifications
with a single arbitrated attention surface — and routes you back to the exact
terminal pane or editor window that needs you.

**Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md). Read §7 and §16 before writing code.**

---

## ⚠️ Current milestone: M0a — spike, not build

Run `make spike`. Do not start M1 until `docs/adr/0004-vscode-first.md` has its
"Spike results" section filled in.

The reordered plan (v0.2) bets on VS Code integration ahead of the CLI provider
matrix. That bet has a dependency — `chatSessionsProvider` is a **proposed** VS
Code API and cannot ship to the Marketplace. The spike answers whether the
stable API exposes enough to make F11a worth building on its own. It does not
take two days to find out, and finding out in month four instead is the
expensive version.

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
