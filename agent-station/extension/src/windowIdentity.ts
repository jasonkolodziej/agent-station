import * as vscode from 'vscode';
import { DaemonClient } from './daemonClient';

/**
 * The load-bearing piece of F11a (ARCHITECTURE.md §7.2).
 *
 * Registering window identity is what lets the daemon map cwd -> open IDE
 * window, which is what makes "Jump to session" work for IDE-hosted runs.
 * Without this the focus router falls all the way through to "activate the
 * app" — right app, wrong tab.
 *
 * All stable API. Nothing here needs a proposal.
 */
export interface WindowIdentity {
  ide: string;
  window_id: string;
  pid: number;
  workspace_roots: string[];
  uri_scheme: string;
  remote_name: string | undefined;
}

export function currentIdentity(): WindowIdentity {
  return {
    ide: vscode.env.appName,                 // "Visual Studio Code" | "Cursor" | ...
    window_id: vscode.env.sessionId,
    pid: process.ppid,
    workspace_roots: vscode.workspace.workspaceFolders?.map(f => f.uri.fsPath) ?? [],
    uri_scheme: vscode.env.uriScheme,        // "vscode" | "cursor" | "vscode-insiders"
    remote_name: vscode.env.remoteName,      // non-undefined => focus routing is a lie
  };
}

export function registerWindowIdentity(
  ctx: vscode.ExtensionContext,
  client: DaemonClient,
): void {
  const send = () => client.send({ event: 'ide.window.registered', ...currentIdentity() });
  send();

  ctx.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(send),
    vscode.window.onDidChangeWindowState(s =>
      client.send({
        event: 'ide.window.focus',
        window_id: vscode.env.sessionId,
        focused: s.focused,
      }),
    ),
  );

  ctx.subscriptions.push({
    dispose: () =>
      client.send({ event: 'ide.window.unregistered', window_id: vscode.env.sessionId }),
  });
}

/**
 * Binds CLI agent sessions launched in the integrated terminal to this window.
 *
 * This is the cheap half of the bridge in §7.4 and it needs NO proposed API:
 * when someone runs `claude` in VS Code's terminal, the shim already captures
 * VSCODE_PID from its environment. We just have to tell the daemon which
 * window that PID belongs to.
 */
export function bindIntegratedTerminals(
  ctx: vscode.ExtensionContext,
  client: DaemonClient,
): void {
  const report = async (t: vscode.Terminal, phase: 'open' | 'close') => {
    const pid = await t.processId;
    client.send({
      event: `ide.terminal.${phase}`,
      window_id: vscode.env.sessionId,
      terminal_pid: pid,
      terminal_name: t.name,
      cwd: (t.shellIntegration?.cwd ?? vscode.workspace.workspaceFolders?.[0]?.uri)?.fsPath,
    });
  };

  vscode.window.terminals.forEach(t => void report(t, 'open'));
  ctx.subscriptions.push(
    vscode.window.onDidOpenTerminal(t => void report(t, 'open')),
    vscode.window.onDidCloseTerminal(t => void report(t, 'close')),
  );
}
