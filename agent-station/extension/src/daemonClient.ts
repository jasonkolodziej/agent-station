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
 *
 * This does NOT send any handshake of its own. The daemon's connection
 * dispatch (agentstationd's UnixSocketServer) determines what a connection
 * *is* from the shape of the first message it receives — `{"op":"subscribe"}`
 * for a pure event subscriber, `{"event":"ide.window.*"}` for a VS Code
 * window (see windowIdentity.ts). Sending an unrecognized first message gets
 * the connection silently dropped, so callers own deciding what to send and
 * when — this client only owns getting bytes there and back.
 */
export class DaemonClient implements vscode.Disposable {
  private sock: net.Socket | undefined;
  private backoffMs = 250;
  private disposed = false;
  private buf = '';
  private readonly eventEmitter = new vscode.EventEmitter<Record<string, unknown>>();
  private readonly connectEmitter = new vscode.EventEmitter<void>();
  readonly onEvent = this.eventEmitter.event;
  /**
   * Fires every time the underlying socket connects — including reconnects
   * after the daemon restarts. Callers that need the daemon to know their
   * current state (window identity, open terminals) must send it here, not
   * once at extension activation: activation happens before the first
   * `connect()` call resolves, and a message sent before 'connect' fires is
   * silently lost (`sock` is still undefined). Re-sending on every reconnect
   * is also what makes state survive a daemon restart mid-session.
   */
  readonly onConnect = this.connectEmitter.event;

  constructor(private readonly socketPath: string = DEFAULT_SOCKET) {}

  connect(): void {
    if (this.disposed) return;
    const s = net.createConnection(this.socketPath);
    s.setEncoding('utf8');

    s.on('connect', () => {
      this.sock = s;
      this.backoffMs = 250;
      this.connectEmitter.fire();
    });
    // setEncoding('utf8') above makes this a string at runtime, but the
    // 'data' event's declared type doesn't track that — decode explicitly
    // rather than asserting past the type error.
    s.on('data', (chunk: Buffer | string) => this.ingest(chunk.toString('utf8')));
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
      try { this.eventEmitter.fire(JSON.parse(line)); } catch { /* ignore junk */ }
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
    this.eventEmitter.dispose();
    this.connectEmitter.dispose();
  }
}
