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
