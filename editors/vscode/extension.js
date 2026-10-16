// VS Code client for the Orin language server. Plain JS, no build step.
// Finds the installed `orin` compiler automatically (see lib/compiler.js), checks that its version
// is supported, launches `<orin> lsp` (LSP over stdio) and shows the state in the status bar.

const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const { execFile } = require("child_process");
const { LanguageClient, TransportKind, State } = require("vscode-languageclient/node");
const { discover, INSTALL_DOCS_URL } = require("./lib/compiler");

const COMPAT = require("./package.json").orinCompiler;

/** @type {LanguageClient | undefined} */
let client;
/** @type {vscode.StatusBarItem | undefined} */
let statusItem;
/** @type {vscode.OutputChannel | undefined} */
let output;
/** @type {Awaited<ReturnType<typeof discover>> | undefined} */
let lastDiscovery;
let lspState = "stopped";

const deps = {
  fs,
  env: process.env,
  homedir: os.homedir(),
  platform: process.platform,
  exec: (cmd, args, opts) =>
    new Promise((resolve) => {
      execFile(cmd, args, { timeout: (opts && opts.timeout) || 10000, encoding: "utf8" }, (err, stdout, stderr) => {
        const code = err ? (typeof err.code === "number" ? err.code : -1) : 0;
        resolve({ code, stdout: stdout || "", stderr: (stderr || "") + (err && !stderr ? String(err.message) : "") });
      });
    }),
};

function log(line) {
  if (output) output.appendLine(line);
}

function updateStatus() {
  if (!statusItem) return;
  const d = lastDiscovery;
  statusItem.command = "orin.showCompilerInfo";
  statusItem.backgroundColor = undefined;
  if (!d || !d.found) {
    statusItem.text = "$(error) Orin: not found";
    statusItem.tooltip = "Orin compiler not found. Click for details.";
    statusItem.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
  } else {
    const v = d.version.kind === "release" ? d.version.raw : d.version.kind === "development" ? "dev" : "?";
    const icon =
      d.compat.status === "incompatible"
        ? "$(error)"
        : lspState === "running"
        ? "$(check)"
        : lspState === "starting"
        ? "$(sync~spin)"
        : "$(warning)";
    statusItem.text = `${icon} Orin ${v}`;
    statusItem.tooltip = `Orin compiler ${d.version.raw} (${d.source}: ${d.path})\nLanguage server: ${lspState}\nClick for details.`;
    if (d.compat.status === "incompatible") {
      statusItem.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    } else if (d.compat.status === "warn" || lspState === "failed") {
      statusItem.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
    }
  }
  statusItem.show();
}

async function offer(message, ...actions) {
  const choice = await vscode.window.showErrorMessage(message, ...actions, "Open install docs");
  if (choice === "Open install docs") {
    vscode.env.openExternal(vscode.Uri.parse(INSTALL_DOCS_URL));
  }
  return choice;
}

async function runDiscovery() {
  const cfg = vscode.workspace.getConfiguration("orin");
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  lastDiscovery = await discover(deps, { serverPath: cfg.get("serverPath"), workspaceFolders: folders, compat: COMPAT });
  log(`discovery: ${lastDiscovery.tried.join(" | ") || "(nothing tried)"}`);
  if (lastDiscovery.found) {
    log(`using ${lastDiscovery.path} (${lastDiscovery.source}), version ${lastDiscovery.version.raw}: ${lastDiscovery.compat.message}`);
  }
  return lastDiscovery;
}

function createClient(command) {
  const serverOptions = { command, args: ["lsp"], transport: TransportKind.stdio };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "orin" }],
    outputChannel: output,
  };
  const c = new LanguageClient("orin", "Orin Language Server", serverOptions, clientOptions);
  c.onDidChangeState((e) => {
    lspState = e.newState === State.Running ? "running" : e.newState === State.Starting ? "starting" : "stopped";
    updateStatus();
  });
  return c;
}

async function startClient() {
  lspState = "starting";
  const d = await runDiscovery();
  if (!d.found) {
    lspState = "stopped";
    updateStatus();
    const detail = d.error || "no `orin` executable found";
    offer(
      `Orin: ${detail}. Install the compiler, or set \`orin.serverPath\`.`,
      "Open settings"
    ).then((c) => {
      if (c === "Open settings") vscode.commands.executeCommand("workbench.action.openSettings", "orin.serverPath");
    });
    return;
  }
  if (d.compat.status === "incompatible") {
    lspState = "stopped";
    updateStatus();
    offer(`Orin: ${d.compat.message}. Update the compiler or install a matching extension version.`);
    return;
  }
  if (d.compat.status === "warn") {
    vscode.window.showWarningMessage(`Orin: ${d.compat.message}`);
  }
  client = createClient(d.path);
  try {
    await client.start();
  } catch (err) {
    client = undefined;
    lspState = "failed";
    updateStatus();
    offer(
      `Orin: could not start the language server (${err && err.message ? err.message : err}). ` +
        "The compiler must support `orin lsp` (release 0.1.0-alpha.2 or newer, or a build from stage 2)."
    );
  }
}

async function stopClient() {
  if (client) {
    const c = client;
    client = undefined;
    try {
      await c.stop();
    } catch (_) {
      // already stopped
    }
  }
  lspState = "stopped";
}

async function restartClient() {
  await stopClient();
  await startClient();
}

async function showCompilerInfo() {
  const d = await runDiscovery();
  output.show(true);
  output.appendLine("--- Orin compiler info ---");
  output.appendLine(`extension supports compiler ${COMPAT.min} or newer in the ${COMPAT.series}.x series`);
  output.appendLine(`language server: ${lspState}`);
  if (!d.found) {
    output.appendLine(`not found: ${d.error}`);
    for (const t of d.tried) output.appendLine(`  tried ${t}`);
    updateStatus();
    await offer(`Orin: ${d.error || "compiler not found"}.`);
    return;
  }
  output.appendLine(`path: ${d.path} (found via ${d.source})`);
  output.appendLine(`version: ${d.version.raw} -> ${d.compat.status}: ${d.compat.message}`);
  if (d.kind !== "dev") {
    // `orin doctor` exists in the release CLI (docs/cli.md); it is not run for dev launchers,
    // which would rebuild the compiler first.
    const r = await deps.exec(d.path, ["doctor"], { timeout: 60000 });
    output.appendLine(`$ ${d.path} doctor (exit ${r.code})`);
    output.appendLine((r.stdout + r.stderr).trimEnd());
  }
  updateStatus();
  vscode.window.showInformationMessage(`Orin ${d.version.raw}: ${d.compat.message}; language server ${lspState}.`);
}

/** @param {vscode.ExtensionContext} context */
async function activate(context) {
  output = vscode.window.createOutputChannel("Orin");
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 50);
  context.subscriptions.push(
    output,
    statusItem,
    vscode.commands.registerCommand("orin.restartServer", restartClient),
    vscode.commands.registerCommand("orin.showCompilerInfo", showCompilerInfo),
    vscode.commands.registerCommand("orin.openInstallDocs", () =>
      vscode.env.openExternal(vscode.Uri.parse(INSTALL_DOCS_URL))
    ),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("orin.serverPath")) {
        restartClient();
      }
    })
  );
  await startClient();
}

function deactivate() {
  return stopClient();
}

module.exports = { activate, deactivate };
