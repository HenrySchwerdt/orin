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

Diagnostics, document symbols and completion (keywords, declarations, imported names) are served
by `orin lsp`; go to definition, hover, find references and rename are enabled once the checker
produces the semantic index. See `spec/18-developer-tooling.md`.

## Develop

```sh
cd editors/vscode
npm install
npm test          # tokenizes sample snippets with vscode-textmate + vscode-oniguruma
```

To try it, open this folder in VS Code and press F5 (Extension Development Host), after
`npm install` (installs `vscode-languageclient`). `node_modules/` is not committed.
