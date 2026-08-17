import * as net from 'net';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

const DEFAULT_SOCKET = path.join(
  os.homedir(), 'Library', 'Application Support', 'AgentStation', 'agentstation.sock',
);

/**
 * Reconnecting UDS client. Backpressure-safe: if the daemon is down we drop
 * messages rather than queue unboundedly. The daemon is the source of truth,
 * not this extension — losing a window-focus ping costs nothing.
 */
export class DaemonClient implements vscode.Disposable {
  private sock: net.Socket | undefined;
  private backoffMs = 250;
  private disposed = false;
  private buf = '';
  private readonly emitter = new vscode.EventEmitter<Record<string, unknown>>();
  readonly onEvent = this.emitter.event;

  constructor(private readonly socketPath: string = DEFAULT_SOCKET) {}

  connect(): void {
    if (this.disposed) return;
    const s = net.createConnection(this.socketPath);
    s.setEncoding('utf8');

    s.on('connect', () => {
      this.sock = s;
      this.backoffMs = 250;
      this.send({ event: 'client.hello', client: 'vscode', v: 1 });
    });
    s.on('data', chunk => this.ingest(chunk));
    s.on('error', () => { /* expected when daemon is down */ });
    s.on('close', () => { this.sock = undefined; this.scheduleReconnect(); });
  }

  private ingest(chunk: string): void {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (!line.trim()) continue;
      try { this.emitter.fire(JSON.parse(line)); } catch { /* ignore junk */ }
    }
  }

  private scheduleReconnect(): void {
    if (this.disposed) return;
    setTimeout(() => this.connect(), this.backoffMs);
    this.backoffMs = Math.min(this.backoffMs * 2, 10_000);
  }

  send(msg: Record<string, unknown>): void {
    this.sock?.write(JSON.stringify(msg) + '\n');
  }

  get connected(): boolean { return this.sock !== undefined; }

  dispose(): void {
    this.disposed = true;
    this.sock?.destroy();
    this.emitter.dispose();
  }
}
