/**
 * F11b — the bidirectional bridge (ARCHITECTURE.md §7.4). INSIDERS ONLY.
 *
 * Registers terminal-hosted agent sessions (claude in iTerm, codex in tmux)
 * as first-class entries in VS Code's Agent Sessions view, alongside Copilot
 * and cloud agents.
 *
 * Neither VS Code (can't see your terminal) nor the CLI-fleet apps (can't see
 * your editor) close this loop. It is the differentiated claim — and it is
 * gated entirely on a proposed API. Read ./README.md before touching this.
 *
 * @proposed chatSessionsProvider
 */
export const SPIKE_NOTES = `
M0a spike — answer these three questions in two days, then decide:

  1. Can a STABLE-API extension observe anything about another extension's
     agent session? (turn completion, confirmation requests, run state)
     If yes -> F11b's read direction may not need the proposal at all.

  2. Does chatSessionsProvider actually accept externally-owned sessions, or
     does it assume the extension owns the agent loop?

  3. What is the install cost of the Insiders + VSIX + --enable-proposed-api
     path for a non-developer user? If it is more than two steps, F11b is a
     demo, not a feature.

Record the answers in docs/adr/0004-vscode-first.md and update the milestone
table in ARCHITECTURE.md 16 accordingly.
`;
