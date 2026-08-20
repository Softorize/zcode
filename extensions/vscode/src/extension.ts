import * as vscode from "vscode";
import { ChildProcessWithoutNullStreams, spawn } from "child_process";
import * as readline from "readline";

type RpcRequest = {
  id: string;
  method: string;
  params: Record<string, unknown>;
};

type RpcResponse = {
  id: string;
  ok: boolean;
  result?: Record<string, unknown>;
  error?: string;
};

type RpcEvent = {
  event: string;
  protocol?: string;
  method?: string;
  ts?: number;
};

type SessionSummary = {
  id: string;
  updated_ts: number;
};

type ProtocolLogMode = "redacted" | "off" | "raw";

function zcodeConfig(): vscode.WorkspaceConfiguration {
  return vscode.workspace.getConfiguration("zcode");
}

function protocolLogMode(): ProtocolLogMode {
  const configured = zcodeConfig().get<string>("protocolLog", "redacted");
  if (configured === "off" || configured === "raw") {
    return configured;
  }
  return "redacted";
}

function apiProfile(): string {
  const configured = zcodeConfig().get<string>("apiProfile", "editor");
  if (configured === "read-only" || configured === "full") {
    return configured;
  }
  return "editor";
}

function redactSensitiveText(text: string): string {
  return text
    .replace(/([?&]token=)[^&\s]+/gi, "$1[redacted]")
    .replace(/(Authorization:\s*Bearer\s+)[^\s]+/gi, "$1[redacted]")
    .replace(/\b(sk-[A-Za-z0-9_-]{10,})\b/g, "[redacted-api-key]");
}

function sanitizeParams(params: Record<string, unknown>): Record<string, unknown> {
  const redacted: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(params)) {
    if (["prompt", "patch", "bundle", "session_id"].includes(key)) {
      redacted[key] = "[redacted]";
    } else if (typeof value === "string") {
      redacted[key] = redactSensitiveText(value);
    } else {
      redacted[key] = value;
    }
  }
  return redacted;
}

function summarizeResult(result: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
  if (!result) {
    return undefined;
  }
  const summary: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(result)) {
    if (key === "output") {
      summary.output = "[redacted]";
    } else if (Array.isArray(value)) {
      summary[key] = `[array:${value.length}]`;
    } else {
      summary[key] = value;
    }
  }
  return summary;
}

function sanitizedRequestLine(payload: RpcRequest): string {
  return JSON.stringify({
    id: payload.id,
    method: payload.method,
    params: sanitizeParams(payload.params),
  });
}

function sanitizedResponseLine(response: RpcResponse): string {
  return JSON.stringify({
    id: response.id,
    ok: response.ok,
    result: summarizeResult(response.result),
    error: response.error ? "[redacted]" : undefined,
  });
}

class ZcodeClient {
  private child: ChildProcessWithoutNullStreams | undefined;
  private rl: readline.Interface | undefined;
  private nextId = 1;
  private pending = new Map<string, (value: RpcResponse) => void>();

  constructor(private readonly output: vscode.OutputChannel) {}

  async request(method: string, params: Record<string, unknown> = {}): Promise<RpcResponse> {
    this.ensureProcess();
    const id = String(this.nextId++);
    const payload: RpcRequest = { id, method, params };
    const line = JSON.stringify(payload);
    this.logOutgoing(payload, line);
    this.child!.stdin.write(`${line}\n`);

    return await new Promise<RpcResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`zcode api request timed out: ${method}`));
      }, 120000);
      const wrapped = (value: RpcResponse) => {
        clearTimeout(timer);
        resolve(value);
      };
      this.pending.set(id, wrapped);
    });
  }

  dispose(): void {
    this.rl?.close();
    this.child?.kill();
    this.pending.clear();
  }

  private ensureProcess(): void {
    if (this.child) {
      return;
    }

    const binaryPath = zcodeConfig().get<string>("binaryPath")?.trim() || "zcode";
    const env = { ...process.env, ZCODE_API_PROFILE: apiProfile() };

    try {
      this.child = spawn(binaryPath, ["api", "serve"], {
        cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath,
        env,
      });
    } catch (error) {
      throw new Error(`failed to start zcode api: ${String(error)}`);
    }

    this.child.stderr.on("data", (chunk: Buffer) => {
      this.output.appendLine(`[stderr] ${redactSensitiveText(chunk.toString("utf8"))}`);
    });

    this.child.on("error", (error) => {
      const message = `failed to launch zcode api: ${String(error)}`;
      this.output.appendLine(message);
      void vscode.window.showErrorMessage(message);
      this.child = undefined;
      this.rl?.close();
      this.rl = undefined;
    });

    this.child.on("exit", (code) => {
      this.output.appendLine(`zcode api exited with code ${code ?? -1}`);
      this.child = undefined;
      this.rl = undefined;
    });

    this.rl = readline.createInterface({ input: this.child.stdout });
    this.rl.on("line", (line: string) => {
      try {
        const parsed = JSON.parse(line) as RpcResponse | RpcEvent;
        this.logIncoming(line, parsed);
        if ("event" in parsed && !("id" in parsed)) {
          this.output.appendLine(`[event] ${parsed.event}${parsed.method ? ` (${parsed.method})` : ""}`);
          return;
        }
        const response = parsed as RpcResponse;
        const handler = this.pending.get(response.id);
        if (handler) {
          this.pending.delete(response.id);
          handler(response);
        }
      } catch (error) {
        this.output.appendLine(`failed to parse zcode api response: ${String(error)}`);
      }
    });
  }

  private logOutgoing(payload: RpcRequest, rawLine: string): void {
    const mode = protocolLogMode();
    if (mode === "off") {
      return;
    }
    this.output.appendLine(`> ${mode === "raw" ? rawLine : sanitizedRequestLine(payload)}`);
  }

  private logIncoming(rawLine: string, parsed: RpcResponse | RpcEvent): void {
    const mode = protocolLogMode();
    if (mode === "off") {
      return;
    }
    if ("event" in parsed && !("id" in parsed)) {
      this.output.appendLine(`< ${mode === "raw" ? rawLine : JSON.stringify(parsed)}`);
      return;
    }
    const response = parsed as RpcResponse;
    this.output.appendLine(`< ${mode === "raw" ? rawLine : sanitizedResponseLine(response)}`);
  }
}

function ensureOk(response: RpcResponse): Record<string, unknown> {
  if (!response.ok) {
    throw new Error(response.error ?? "zcode api request failed");
  }
  return response.result ?? {};
}

function showTextDocument(title: string, body: string, language = "markdown"): Thenable<vscode.TextEditor> {
  return vscode.workspace.openTextDocument({ content: body, language }).then((doc) => {
    return vscode.window.showTextDocument(doc, { preview: false }).then((editor) => {
      void vscode.languages.setTextDocumentLanguage(doc, language);
      void vscode.commands.executeCommand("workbench.action.files.setActiveEditorReadonlyInSession");
      return editor;
    });
  });
}

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c]!));
}

function classifyDiffLine(line: string): "hunk" | "file-from" | "file-to" | "added" | "removed" | "context" {
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+++")) return "file-to";
  if (line.startsWith("---")) return "file-from";
  if (line.startsWith("+")) return "added";
  if (line.startsWith("-")) return "removed";
  return "context";
}

function renderPatchPreview(patch: string): string {
  const lines = patch.split(/\r?\n/);
  let added = 0;
  let removed = 0;
  let hunks = 0;
  const body = lines
    .map((line, idx) => {
      const kind = classifyDiffLine(line);
      if (kind === "added") added += 1;
      else if (kind === "removed") removed += 1;
      else if (kind === "hunk") hunks += 1;
      const lineNumber = String(idx + 1).padStart(4, " ");
      return `<div class="ln ln-${kind}"><span class="gutter">${lineNumber}</span><span class="text">${escapeHtml(line) || "&nbsp;"}</span></div>`;
    })
    .join("");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>zcode patch preview</title>
<style>
  :root {
    --bg: #0e1116;
    --bg-raised: #151a21;
    --bg-elevated: #1b2128;
    --border: #222833;
    --border-strong: #2f3742;
    --fg: #e6edf3;
    --fg-dim: #8a94a6;
    --fg-muted: #5b6573;
    --accent: #5fd4a0;
    --accent-soft: rgba(95, 212, 160, 0.12);
    --added-bg: rgba(72, 187, 120, 0.09);
    --added-fg: #88d8a8;
    --added-marker: #4fb97a;
    --removed-bg: rgba(231, 98, 124, 0.09);
    --removed-fg: #e8909c;
    --removed-marker: #d95f72;
    --hunk-fg: #7fb4ff;
    --hunk-bg: rgba(127, 180, 255, 0.08);
    --file-fg: #c9b6ff;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
  body {
    font-family: "Geist Mono", "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    font-size: 13px;
    line-height: 1.55;
    letter-spacing: 0.01em;
    font-feature-settings: "calt" 1, "liga" 0;
    -webkit-font-smoothing: antialiased;
    background-image: radial-gradient(circle at 0% 0%, rgba(95, 212, 160, 0.04) 0%, transparent 45%);
  }
  .shell {
    max-width: 1180px;
    margin: 0 auto;
    padding: 0;
  }
  .header {
    position: sticky;
    top: 0;
    z-index: 2;
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 20px 28px;
    background: linear-gradient(180deg, var(--bg-raised) 0%, rgba(21, 26, 33, 0.85) 100%);
    backdrop-filter: blur(6px);
    border-bottom: 1px solid var(--border);
  }
  .header::before {
    content: "";
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 3px;
    background: var(--accent);
  }
  .brand {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: "Geist", "Inter", -apple-system, system-ui, sans-serif;
    font-weight: 600;
    font-size: 15px;
    letter-spacing: -0.01em;
  }
  .brand .mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 6px;
    background: var(--accent-soft);
    color: var(--accent);
    font-size: 12px;
    font-weight: 700;
  }
  .title {
    color: var(--fg-dim);
    font-weight: 500;
    font-size: 13px;
  }
  .stats {
    margin-left: auto;
    display: flex;
    gap: 16px;
    font-family: "Geist Mono", "SF Mono", ui-monospace, Menlo, monospace;
    font-size: 12px;
    font-variant-numeric: tabular-nums;
    color: var(--fg-muted);
  }
  .stats .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 999px;
    background: var(--bg-elevated);
    border: 1px solid var(--border);
  }
  .stats .chip.added { color: var(--added-fg); border-color: rgba(79, 185, 122, 0.3); }
  .stats .chip.removed { color: var(--removed-fg); border-color: rgba(217, 95, 114, 0.3); }
  .stats .chip.hunks { color: var(--hunk-fg); border-color: rgba(127, 180, 255, 0.3); }
  .stats .dot { width: 6px; height: 6px; border-radius: 999px; background: currentColor; }
  .body {
    padding: 0;
  }
  .ln {
    display: flex;
    align-items: flex-start;
    padding: 0;
    min-height: 20px;
  }
  .ln .gutter {
    flex: 0 0 56px;
    padding: 0 12px 0 28px;
    text-align: right;
    color: var(--fg-muted);
    font-variant-numeric: tabular-nums;
    user-select: none;
    border-right: 1px solid var(--border);
  }
  .ln .text {
    flex: 1;
    padding: 0 16px;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .ln-added { background: var(--added-bg); border-left: 2px solid var(--added-marker); }
  .ln-added .text { color: var(--added-fg); }
  .ln-removed { background: var(--removed-bg); border-left: 2px solid var(--removed-marker); }
  .ln-removed .text { color: var(--removed-fg); }
  .ln-hunk { background: var(--hunk-bg); }
  .ln-hunk .text { color: var(--hunk-fg); font-weight: 500; }
  .ln-file-from .text, .ln-file-to .text { color: var(--file-fg); font-weight: 500; }
  .ln-context .text { color: var(--fg-dim); }
</style>
</head>
<body>
<div class="shell">
  <header class="header">
    <div class="brand">
      <span class="mark">z</span>
      <span>zcode</span>
    </div>
    <span class="title">patch preview</span>
    <div class="stats">
      <span class="chip added"><span class="dot"></span>+${added}</span>
      <span class="chip removed"><span class="dot"></span>-${removed}</span>
      <span class="chip hunks"><span class="dot"></span>${hunks} hunk${hunks === 1 ? "" : "s"}</span>
    </div>
  </header>
  <main class="body">
    ${body}
  </main>
</div>
</body>
</html>`;
}

function coerceSessions(result: Record<string, unknown>): SessionSummary[] {
  const raw = result.sessions;
  if (Array.isArray(raw)) {
    return raw
      .map((item) => {
        if (!item || typeof item !== "object") {
          return undefined;
        }
        const value = item as Record<string, unknown>;
        if (typeof value.id !== "string" || typeof value.updated_ts !== "number") {
          return undefined;
        }
        return { id: value.id, updated_ts: value.updated_ts };
      })
      .filter((value): value is SessionSummary => value !== undefined);
  }

  const output = typeof result.output === "string" ? result.output : "";
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && line !== "no sessions")
    .map((line) => {
      const [id, updatedPart] = line.split("\t");
      const updated_ts = Number((updatedPart ?? "").replace(/^updated=/, ""));
      if (!id || Number.isNaN(updated_ts)) {
        return undefined;
      }
      return { id, updated_ts };
    })
    .filter((value): value is SessionSummary => value !== undefined);
}

function formatUpdatedTs(updatedTs: number): string {
  const millis = updatedTs < 10_000_000_000 ? updatedTs * 1000 : updatedTs;
  return new Date(millis).toLocaleString();
}

async function pickSession(client: ZcodeClient, title: string): Promise<string | undefined> {
  const result = ensureOk(await client.request("session.list"));
  const sessions = coerceSessions(result).sort((a, b) => b.updated_ts - a.updated_ts);
  if (sessions.length === 0) {
    void vscode.window.showWarningMessage("No zcode sessions found.");
    return undefined;
  }

  const picked = await vscode.window.showQuickPick(
    sessions.map((session) => ({
      label: session.id,
      description: `updated ${formatUpdatedTs(session.updated_ts)}`,
      session,
    })),
    { title, placeHolder: "Select a zcode session" },
  );
  return picked?.session.id;
}

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel("zcode");
  const client = new ZcodeClient(output);
  context.subscriptions.push(output, { dispose: () => client.dispose() });

  context.subscriptions.push(vscode.commands.registerCommand("zcode.status", async () => {
    const result = ensureOk(await client.request("status"));
    output.show(true);
    output.appendLine(JSON.stringify(result, null, 2));
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.runPrompt", async () => {
    const prompt = await vscode.window.showInputBox({ prompt: "Prompt for zcode" });
    if (!prompt) {
      return;
    }
    const result = ensureOk(await client.request("run", { prompt }));
    await showTextDocument("zcode run", String(result.output ?? ""), "markdown");
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.reviewWorking", async () => {
    const result = ensureOk(await client.request("review", { target: "working" }));
    await showTextDocument("zcode review", String(result.output ?? ""), "markdown");
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.applySelectedPatch", async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      void vscode.window.showErrorMessage("Open an editor with a unified diff selection first.");
      return;
    }
    const selection = editor.selection;
    const patch = selection.isEmpty ? editor.document.getText() : editor.document.getText(selection);
    if (!patch.trim()) {
      void vscode.window.showErrorMessage("No patch text found.");
      return;
    }

    const panel = vscode.window.createWebviewPanel("zcodePatchPreview", "zcode Patch Preview", vscode.ViewColumn.Beside, {});
    panel.webview.html = renderPatchPreview(patch);

    const choice = await vscode.window.showWarningMessage("Apply the selected patch through zcode?", { modal: true }, "Apply");
    if (choice !== "Apply") {
      return;
    }
    const result = ensureOk(await client.request("diff.apply", { patch }));
    void vscode.window.showInformationMessage(String(result.output ?? "patch applied"));
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.shareSession", async () => {
    const sessionId = await pickSession(client, "Share zcode session");
    if (!sessionId) {
      return;
    }
    const label = await vscode.window.showInputBox({ prompt: "Share label", value: "editor-handoff" });
    const result = ensureOk(await client.request("session.share", { session_id: sessionId, label }));
    await showTextDocument("zcode session share", String(result.output ?? ""), "plaintext");
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.webHandoffSession", async () => {
    const sessionId = await pickSession(client, "Web handoff zcode session");
    if (!sessionId) {
      return;
    }
    const label = await vscode.window.showInputBox({ prompt: "Handoff label", value: "editor-handoff" });
    const result = ensureOk(await client.request("session.handoff", { session_id: sessionId, label }));
    await showTextDocument("zcode web handoff", String(result.output ?? ""), "plaintext");
  }));

  context.subscriptions.push(vscode.commands.registerCommand("zcode.importSharedSession", async () => {
    const bundle = await vscode.window.showInputBox({
      prompt: "Bundle path or handoff URL",
      placeHolder: "https://127.0.0.1:8766/share/... or /path/to/bundle.json",
    });
    if (!bundle) {
      return;
    }
    const result = ensureOk(await client.request("session.import", { bundle }));
    await showTextDocument("zcode import shared session", String(result.output ?? ""), "plaintext");
  }));
}

export function deactivate(): void {}
