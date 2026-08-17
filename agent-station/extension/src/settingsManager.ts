import * as vscode from 'vscode';

/**
 * Notification suppression (ARCHITECTURE.md §7.1, step 1).
 *
 * IMPORTANT AND OFTEN MISUNDERSTOOD: you cannot intercept another extension's
 * showInformationMessage, and you cannot suppress an OS notification another
 * process posted. There is no API for that and there shouldn't be.
 *
 * What actually works is turning the source off at its own setting, then taking
 * over the signal via hooks. Keys are provider-specific and resolved from the
 * manifest at runtime so this survives upstream renames.
 */
export interface SuppressionRule {
  provider: string;
  /** Settings keys to force false. Resolved from the daemon's manifest set. */
  keys: string[];
}

const BACKUP_KEY = 'agentStation.settingsBackup.v1';

export class SettingsManager {
  constructor(private readonly ctx: vscode.ExtensionContext) {}

  /** Returns a human-readable diff. Never writes without explicit confirmation. */
  async preview(rules: SuppressionRule[]): Promise<string[]> {
    const cfg = vscode.workspace.getConfiguration();
    const lines: string[] = [];
    for (const rule of rules) {
      for (const key of rule.keys) {
        const current = cfg.inspect(key)?.globalValue;
        if (current !== false) lines.push(`- ${key}: ${JSON.stringify(current)} -> false`);
      }
    }
    return lines;
  }

  async apply(rules: SuppressionRule[]): Promise<void> {
    const diff = await this.preview(rules);
    if (diff.length === 0) {
      vscode.window.showInformationMessage('Agent Station: nothing to change.');
      return;
    }
    const choice = await vscode.window.showInformationMessage(
      `Agent Station will change ${diff.length} setting(s):\n${diff.join('\n')}`,
      { modal: true },
      'Apply', 'Cancel',
    );
    if (choice !== 'Apply') return;

    const cfg = vscode.workspace.getConfiguration();
    const backup: Record<string, unknown> = this.ctx.globalState.get(BACKUP_KEY) ?? {};
    for (const rule of rules) {
      for (const key of rule.keys) {
        if (!(key in backup)) backup[key] = cfg.inspect(key)?.globalValue ?? null;
        await cfg.update(key, false, vscode.ConfigurationTarget.Global);
      }
    }
    await this.ctx.globalState.update(BACKUP_KEY, backup);
  }

  /** One-click revert. Must always work, or nobody will let us touch settings. */
  async restore(): Promise<void> {
    const backup = this.ctx.globalState.get<Record<string, unknown>>(BACKUP_KEY) ?? {};
    const cfg = vscode.workspace.getConfiguration();
    for (const [key, value] of Object.entries(backup)) {
      await cfg.update(key, value ?? undefined, vscode.ConfigurationTarget.Global);
    }
    await this.ctx.globalState.update(BACKUP_KEY, undefined);
    vscode.window.showInformationMessage('Agent Station: original notification settings restored.');
  }
}
