# 0004 — VS Code before the CLI provider matrix

Supersedes the v0.1 milestone ordering, which built CLI adapters first.

## Context
Three facts, in ascending order of force:

1. VS Code's model picker spans providers, so one Class D adapter rides along
   with every model a user switches to. **Caveat:** that is N models under one
   harness, not N agents. Copilot agent mode with Claude selected behaves like
   Copilot, not like Claude Code. Leverage, not coverage.
2. VS Code is the substrate beneath Cursor, Devin's editor surfaces, and most
   enterprise IDE-agent deployments. Cursor loads the same extension.
3. **The decisive one:** VS Code already shipped the aggregator. The Agent
   Sessions view is explicitly positioned as "mission control" for local and
   cloud agents, with a title-bar indicator carrying in-progress and unread
   badges. AgentMax ships the CLI-fleet equivalent.

Aggregation is therefore table stakes that two other parties already ship. What
neither can do is reach you when the editor isn't frontmost, or when the run
lives in iTerm.

## Decision
- F11a (stable API: window identity, URI handler, focus routing, notification
  suppression, integrated-terminal binding) moves to **M1**.
- F10 (CLI provider matrix) moves to **M6**, by which point the manifest system
  makes each provider cheap.
- F11b (the `chatSessionsProvider` bridge) is **gated on a spike**, M0a.

## The constraint that governs all of this
`chatSessionsProvider` is a **proposed** API. Proposed APIs are Insiders-only
and cannot be used in published extensions; `vsce` hard-errors on publish when
`enabledApiProposals` is present. The blessed-extension escape hatch is an
allowlist in VS Code's `product.json` that only Microsoft controls.

So F11b cannot reach the Marketplace today. Distribution would be
VSIX + Insiders + `--enable-proposed-api`, a hostile path for a consumer utility.

## Consequences
- The first task in the plan is a two-day spike, not a build. Answer: *what can
  a stable-API extension actually observe about another extension's agent
  session?* If the answer is "essentially nothing," F11a still ships — focus
  routing and suppression are the load-bearing parts — but the bridge narrative
  becomes an Insiders preview and the roadmap must say so out loud.
- Uncomfortable: **the notch is no longer the first thing built.** M1–M2 ship
  value through the VS Code status bar and the menu bar. The alternative is
  polishing a panel before knowing whether there's anything reliable to put in it.

## What would reverse this
- The M0a spike finding that stable APIs expose enough for the read direction —
  then F11b partially un-gates and moves earlier.
- `chatSessionsProvider` stalling two release cycles — then cut the bridge from
  the pitch entirely and lead with focus routing.
- Microsoft shipping out-of-editor surfacing itself — then the remaining moat is
  the terminal half, and F10 becomes urgent again.

## Spike results
> _Fill this in before writing M1 code._
> 1. Stable-API observability of foreign agent sessions:
> 2. Does `chatSessionsProvider` accept externally-owned sessions?
> 3. Install cost of the Insiders path (steps for a non-developer):
> Decision:
