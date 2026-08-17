import * as vscode from 'vscode';
import { DaemonClient } from './daemonClient';
import { registerWindowIdentity, bindIntegratedTerminals } from './windowIdentity';
import { registerUriHandler } from './uriHandler';
import { SettingsManager } from './settingsManager';
import { StatusBar } from './statusBar';

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
      client.send({ event: 'query.suppression_rules' });
    }),
    vscode.commands.registerCommand('agentStation.showSessions', () => {
      client.send({ event: 'ui.expand_requested', source: 'vscode' });
    }),
  );

  client.connect();
}

export function deactivate(): void {}
