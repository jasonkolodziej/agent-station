import * as vscode from 'vscode';

/**
 * The return path. The island's "Jump to session" opens
 *   vscode://agentstation.agent-station/session/<id>?file=<path>&line=<n>
 * and macOS routes it to the right window because the daemon picked the
 * scheme + window from the identity registry.
 */
export function registerUriHandler(ctx: vscode.ExtensionContext): void {
  ctx.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri: vscode.Uri) {
        const params = new URLSearchParams(uri.query);
        const file = params.get('file');

        if (file) {
          const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
          const editor = await vscode.window.showTextDocument(doc, { preview: false });
          const line = Number(params.get('line') ?? 0);
          if (line > 0) {
            const pos = new vscode.Position(line - 1, 0);
            editor.selection = new vscode.Selection(pos, pos);
            editor.revealRange(new vscode.Range(pos, pos), vscode.TextEditorRevealType.InCenter);
          }
        }

        // Focus the editor group, then the chat surface if the session is one.
        await vscode.commands.executeCommand('workbench.action.focusActiveEditorGroup');
        if (params.get('surface') === 'chat') {
          await vscode.commands.executeCommand('workbench.action.chat.open');
        }
      },
    }),
  );
}
