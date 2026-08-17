# 0003 — Zero-dependency Rust shim, and it does not parse the payload

## Context
The shim runs on every agent lifecycle event. Gemini CLI runs hooks
synchronously inside the agent loop and waits for them before continuing;
Claude Code's `UserPromptSubmit`/`PreToolUse` gate the turn. Hook latency is
agent latency.

Two costs dominate a short-lived process: dynamic linking and parsing.

## Decision
1. **Rust, no crates.** Not Swift: loading Foundation costs more dyld work than
   the entire latency budget. Not a script: interpreter startup is worse.
2. **The shim does not parse the provider payload.** It splices the raw bytes
   into an envelope as a verbatim `raw` member. The daemon parses, and the
   daemon is not on the hot path.
3. **Every error path exits 0.** If the socket file is absent we return before
   attempting to connect.

## Consequences
- Malformed payloads surface as daemon-side diagnostics, not shim failures —
  which is correct, because the shim has no way to report them usefully anyway.
- Reply parsing is hand-rolled and deliberately minimal (two shapes). Anything
  unrecognised fails open.
- `shim/tests/latency.rs` asserts a p99 on the fail-open path. Treat a failure
  there as a release blocker, not a flaky test: it means every user's agent got
  slower.

## What would reverse this
Measured evidence that a serde-based shim stays under budget across cold-start
conditions. Measure before assuming; process spawn dominates and the difference
may be smaller than it looks.
