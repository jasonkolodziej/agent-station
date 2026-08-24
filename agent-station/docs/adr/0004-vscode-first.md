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

_Closed 2026-08-24. Method: inspected the installed stable `@types/vscode@1.134.0`
(matches locally installed VS Code 1.134.0) plus the live proposed d.ts pulled
via `npx vscode-dts dev` from `microsoft/vscode@main` into `.spike/`. No
`code-insiders` was available on this machine, so Q2 is answered from the type
surface and API doc comments, not a running Insiders session — flagged below._

**1. Stable-API observability of foreign agent sessions: essentially nothing.**
The entire stable `vscode.chat` namespace is one function:
`createChatParticipant(id, handler)`. There is no stable session list, no
turn-completion event, no confirmation/approval event, and no way to subscribe
to another extension's chat activity. `vscode.extensions.all` /
`getExtension()` only report install/enable state, not runtime session state —
observing a foreign extension's live state would require that extension to
opt in via its own `Extension.exports` API, which Copilot does not do for this
purpose. This confirms §7.1's claim directly rather than just asserting it:
**there is no interception point for another extension's notifications or
session state on the stable API**, full stop. Nothing here changes — F11a's
"take over the signal via hooks" design (§7.1 step 2) is not optional, it's
the only path.

**2. Does `chatSessionsProvider` accept externally-owned sessions? Yes, by
design — but the API has moved since §7.4/§7.5 were written.**
`registerChatSessionItemProvider` / `ChatSessionItemProvider` are now
**`@deprecated`**, superseded by `chat.createChatSessionItemController(type,
refreshHandler)` returning a `ChatSessionItemController`. The controller
pattern is a push-based collection (`items.add/replace/delete`), not a
callback the editor drives — which is exactly the externally-owned shape we
need: the extension creates `ChatSessionItem`s (`createChatSessionItem(uri,
label)`) whenever it learns about a session (i.e., when our own hook/UDS
stream sees `session.started` for a terminal-hosted Claude Code/Codex run) and
pushes them into the collection on its own schedule. Confirming the read-only
angle: `ChatSessionContentProvider.provideChatSessionContent` returns a
`ChatSession` whose `requestHandler` may be `undefined`, and the doc comment
says explicitly *"If not set, then the session will be considered read-only
and no requests can be made."* That's precisely our case — Agent Station
observes a CLI-owned agent loop, it doesn't drive it. `ChatSessionItem` also
carries `status: ChatSessionStatus` (`InProgress`/`NeedsInput`/`Completed`/
`Failed`) and `badge`/`changes` fields, enough to render exactly what §7.4's
diagram wants (unread badges, status, click-to-jump).
Caveat: this reads the *design intent* from the proposal's current type shape
and doc comments, not a confirmed live round-trip in Insiders — genuinely
verifying it means running the Q2 steps from `spike-m0a.sh` with
`code-insiders` installed. That remains open before M5 implementation starts,
not before M1.

**3. Install cost of the Insiders path: 4 steps, 2+ requiring a terminal — still a demo.**
1. Install VS Code Insiders as a *separate* app (not upgrading their existing
   VS Code).
2. Obtain the VSIX out-of-band (can't come from the Marketplace by
   definition).
3. Extensions view → "Install from VSIX…".
4. Quit and relaunch from a terminal with `code-insiders
   --enable-proposed-api agentstation.station-bridge` — the proposed-API flag
   is a CLI launch argument, not something a normal `.app` double-click can
   carry, so every session needs to originate from that terminal invocation
   (or a wrapper script/alias) rather than Spotlight/Dock.

That clears the ">2 steps → demo" bar from `spike-m0a.sh` on step count alone,
before even counting the friction of step 4 recurring on every launch. F11b is
a demo/preview feature for the foreseeable future, not a mainstream install
path.

**Decision:**
- Proceed to **M1** (F11a: window identity, URI handler, notification
  suppression, integrated-terminal binding, status bar) on the stable API, as
  already reordered in ARCHITECTURE.md §16. Nothing in this spike weakens that
  case — if anything, Q1 makes the "we own the only signal-suppression path"
  claim in §7.1 stronger, not weaker.
- **F11b stays gated behind Insiders**, exactly as §7.5 already planned, but
  target the **current, non-deprecated** shape
  (`createChatSessionItemController` / `ChatSessionItemController` /
  `ChatSessionContentProvider`) rather than the `registerChatSessionItemProvider`
  API named in §7.4/§7.5 — that one is deprecated as of this check and
  shouldn't be built against.
- Before M5 build work starts, re-run Q2 for real in `code-insiders` (this
  machine doesn't have it) to confirm the read-only/`requestHandler:
  undefined` path actually renders as expected, not just that the types allow
  it.
- Re-check proposal status each VS Code release per open question 6 in §17 —
  it was still living under `vscode.proposed.chatSessionsProvider.d.ts` on
  `microsoft/vscode@main` as of this check, i.e. not finalized.
