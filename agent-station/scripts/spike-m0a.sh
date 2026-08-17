#!/usr/bin/env bash
# M0a — the two-day spike that gates the whole reordered plan.
# Do this BEFORE writing product code. See docs/adr/0004-vscode-first.md.
set -euo pipefail

cat <<'NOTE'
M0a SPIKE — VS Code observability

Question 1: What can a STABLE-API extension observe about another extension's
            agent session?
  - Install Copilot + Claude Code extension in a scratch profile
  - From a stable-API extension, attempt to observe: turn completion,
    confirmation requests, run state, session list
  - Record what is reachable WITHOUT enabledApiProposals

Question 2: Does chatSessionsProvider accept externally-owned sessions, or does
            it assume the extension owns the agent loop?
  - Requires VS Code Insiders
  - npx vscode-dts dev            # pull proposed d.ts files
  - Add "enabledApiProposals": ["chatSessionsProvider"] to a THROWAWAY manifest
  - code-insiders --enable-proposed-api agentstation.spike

Question 3: Install cost of the Insiders + VSIX + --enable-proposed-api path
            for a non-developer. Count the steps. If >2, F11b is a demo.

EXIT CRITERIA — write answers into docs/adr/0004-vscode-first.md "Spike results"
and update the milestone table in ARCHITECTURE.md §16. Do not start M1 until
that section is filled in.
NOTE

command -v code-insiders >/dev/null || echo "WARN: code-insiders not on PATH — Q2 needs it"
mkdir -p .spike && echo "Scratch dir: .spike/"
