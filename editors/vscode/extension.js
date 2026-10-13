// VS Code client for the Orin language server. Plain JS, no build step.
// Launches `<orin.serverPath> lsp` (default `orin lsp`) and talks LSP over stdio.

const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

/** @type {LanguageClient | undefined} */
let client;

function createClient() {
  const command = vscode.workspace.getConfiguration("orin").get("serverPath") || "orin";
  const serverOptions = {
    command,
    args: ["lsp"],
    transport: TransportKind.stdio,
  };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "orin" }],
  };
  return new LanguageClient("orin", "Orin Language Server", serverOptions, clientOptions);
}

async function startClient() {
  client = createClient();
  try {
    await client.start();
  } catch (err) {
    client = undefined;
    vscode.window.showErrorMessage(
      `Orin: could not start the language server (${err && err.message ? err.message : err}). ` +
        "Set `orin.serverPath` to the `orin` executable."
    );
  }
}

async function stopClient() {
  if (client) {
    const c = client;
    client = undefined;
    await c.stop();
  }
}

async function restartClient() {
  await stopClient();
  await startClient();
}

/** @param {vscode.ExtensionContext} context */
async function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("orin.restartServer", restartClient),
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
