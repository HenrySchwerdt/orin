# Orin for VS Code

Minimal extension for the Orin language (spec 18, "Editor integration"):

- Language `orin` for `*.or` files, with comments, brackets and auto-closing pairs
  (`language-configuration.json`).
- TextMate grammar `syntaxes/orin.tmLanguage.json` (highlighting only): keywords including the
  reserved words (flagged illegal), primitive/builtin types, `true`/`false`, decimal and hex
  literals, strings with escapes, line/block comments, function/type/const/let declaration
  names and `@Annotation`s.
- `extension.js` starts the language server `orin lsp` (LSP over stdio) with
  `vscode-languageclient`. Plain JavaScript, no build step.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `orin.serverPath` | `orin` | Path of the `orin` executable (run as `orin lsp`). Changing it restarts the server. |
| `orin.trace.server` | `off` | LSP trace level (`off`, `messages`, `verbose`). |

Command: **Orin: Restart Language Server**.

## Server features

`orin lsp` serves diagnostics (E-codes with exact ranges, for every open file and the files it
imports), document symbols, completion (locals and parameters in scope, declarations, imported
names, keywords, built-ins), formatting (the canonical `orin fmt` layout), go to definition,
hover (signature or type), find references and rename, across modules. Rename is refused while the
workspace has errors, because the semantic index is then partial. See
`spec/18-developer-tooling.md`.

## Using the language server

1. Build the compiler: `./tools/bootstrap.sh` produces `build/bootstrap/orin2` (a self-hosted
   `orin`; the `lsp` command needs a build from stage 2 on, which this is).
2. Point the extension at it, in the VS Code settings (JSON):

   ```json
   { "orin.serverPath": "/absolute/path/to/build/bootstrap/orin2" }
   ```

   The extension runs `<serverPath> lsp` (LSP over stdio). Any editor with a generic LSP client
   works the same way: command `orin`, argument `lsp`, language id `orin`, files `*.or`.
3. Open a `.or` file. Every open document is analysed as its own entry (a missing `main` is
   tolerated); unsaved buffers are used for imported modules too.

Check it without an editor: `python3 tools/test_lsp.py` drives a freshly built `orin lsp` with real
JSON-RPC messages.

## Develop

```sh
cd editors/vscode
npm install
npm test          # tokenizes sample snippets with vscode-textmate + vscode-oniguruma
```

To try it, open this folder in VS Code and press F5 (Extension Development Host), after
`npm install` (installs `vscode-languageclient`). `node_modules/` is not committed.
