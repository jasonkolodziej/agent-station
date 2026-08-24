import * as vscode from 'vscode';
import { DaemonClient } from './daemonClient';
import { registerWindowIdentity, bindIntegratedTerminals } from './windowIdentity';
import { registerUriHandler } from './uriHandler';
import { SettingsManager, SuppressionRule } from './settingsManager';
import { StatusBar } from './statusBar';

/**
 * Sends `query.suppression_rules` and waits for the daemon's matching
 * `suppression_rules` reply on the same connection. One-shot: registers a
 * listener, resolves on the first matching message (or the timeout), then
 * always disposes — `client.onEvent` fires for everything on this
 * connection (canonical events, ui.counts), not just replies to this query.
 */
function requestSuppressionRules(client: DaemonClient): Promise<SuppressionRule[]> {
  return new Promise(resolve => {
    let settled = false;
    const sub = client.onEvent(msg => {
      if (msg['event'] !== 'suppression_rules' || settled) return;
      settled = true;
      sub.dispose();
      clearTimeout(timer);
      resolve((msg['rules'] as SuppressionRule[] | undefined) ?? []);
    });
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      sub.dispose();
      resolve([]);
    }, 3_000);
    client.send({ event: 'query.suppression_rules' });
  });
}

/**
 * M1 — F11a. Everything here is stable API and Marketplace-publishable.
 * Do not import from ./proposed. See docs/adr/0004-vscode-first.md.
 */
export function activate(ctx: vscode.ExtensionContext): void {
  const cfgPath = vscode.workspace.getConfiguration('agentStation').get<string>('socketPath');
  const client = cfgPath ? new DaemonClient(cfgPath) : new DaemonClient();
  const statusBar = new StatusBar();
  const settings = new SettingsManager(ctx);

  ctx.subscriptions.push(client, statusBar);

  registerWindowIdentity(ctx, client);
  registerUriHandler(ctx);
  if (vscode.workspace.getConfiguration('agentStation').get('bindIntegratedTerminalSessions')) {
    bindIntegratedTerminals(ctx, client);
  }

  client.onEvent(msg => {
    if (msg['event'] === 'ui.counts') {
      statusBar.update({
        running: msg['running'] as number,
        needsAttention: msg['needs_attention'] as number,
        connected: true,
      });
    }
  });

  ctx.subscriptions.push(
    vscode.commands.registerCommand('agentStation.reconnect', () => client.connect()),
    vscode.commands.registerCommand('agentStation.restoreProviderNotifications', () =>
      settings.restore()),
    vscode.commands.registerCommand('agentStation.suppressProviderNotifications', async () => {
      // Rules come from the daemon's manifest set, not hardcoded here — that's
      // what makes this survive upstream setting renames.
      const rules = await requestSuppressionRules(client);
      if (rules.length === 0) {
        vscode.window.showInformationMessage(
          'Agent Station: no notification suppression rules available yet — no connected provider manifest declares any.',
        );
        return;
      }
      await settings.apply(rules);
    }),
    vscode.commands.registerCommand('agentStation.showSessions', () => {
      client.send({ event: 'ui.expand_requested', source: 'vscode' });
    }),
  );

  client.connect();
}

export function deactivate(): void {}
