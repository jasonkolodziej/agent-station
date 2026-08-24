# 0002 — AF_UNIX + JSON Lines, not HTTP

## Decision
`~/Library/Application Support/AgentStation/agentstation.sock`, mode 0600,
newline-delimited JSON, 256KB frame cap.

## Rationale
- No port means no localhost attack surface and no conflict with a dev server.
- Peer identity is free: `LOCAL_PEERCRED` gives uid without a token exchange.
- The socket file's *absence* is a fast, cheap "daemon is down" signal for the
  shim's fail-open path — a `stat` instead of a connect timeout.

## Consequences
- Code-signature validation of the connecting binary is required for the
  **decision** channel only. Approving a shell command is a privileged act;
  reporting a completion is not. Validating everything would put a signature
  check on the hot path.
- Remote/SSH sessions are out of scope. `SSH_TTY` in the focus context is a
  marker for "focus routing is a lie here," not something we try to solve.
- **The daemon can't parse frames by splitting on `\n`, even though the wire
  format is JSONL.** The shim splices a provider's raw payload into the
  envelope byte-verbatim and never reformats it (ADR-0003) — a pretty-printed
  provider payload puts literal newline bytes inside a single frame, before
  the frame is actually over. Discovered when a checked-in fixture (itself
  pretty-printed) silently failed to reach the normalizer. `UnixSocketServer`
  reads one top-level JSON value by tracking brace/bracket depth and string
  escaping instead of scanning for `\n`. Each frame is still written with a
  trailing newline — that stays a convention for tooling (`nc`, log capture)
  to read by, not something the parser itself depends on.
