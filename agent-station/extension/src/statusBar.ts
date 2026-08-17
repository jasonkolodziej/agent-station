import * as vscode from 'vscode';

/** M1 ships value here, before the notch panel exists. */
export class StatusBar implements vscode.Disposable {
  private readonly item: vscode.StatusBarItem;
  private running = 0;
  private needsAttention = 0;
  private connected = false;

  constructor() {
    this.item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    this.item.command = 'agentStation.showSessions';
    this.render();
    this.item.show();
  }

  update(p: { running?: number; needsAttention?: number; connected?: boolean }): void {
    if (p.running !== undefined) this.running = p.running;
    if (p.needsAttention !== undefined) this.needsAttention = p.needsAttention;
    if (p.connected !== undefined) this.connected = p.connected;
    this.render();
  }

  private render(): void {
    if (!this.connected) {
      this.item.text = '$(debug-disconnect) Station';
      this.item.tooltip = 'Agent Station daemon not running';
      this.item.backgroundColor = undefined;
      return;
    }
    if (this.needsAttention > 0) {
      this.item.text = `$(bell-dot) ${this.needsAttention}`;
      this.item.tooltip = `${this.needsAttention} agent run(s) waiting on you`;
      this.item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
      return;
    }
    this.item.text = this.running > 0 ? `$(sync~spin) ${this.running}` : '$(check) Station';
    this.item.tooltip = `${this.running} agent run(s) in flight`;
    this.item.backgroundColor = undefined;
  }

  dispose(): void { this.item.dispose(); }
}
