# Orin for VS Code

Minimal extension for the Orin language (spec 18, "Editor integration"):

- Language `orin` for `*.or` files, with comments, brackets and auto-closing pairs
  (`language-configuration.json`).
- TextMate grammar `syntaxes/orin.tmLanguage.json` (highlighting only): keywords including the
  reserved words (flagged illegal), primitive/builtin types, `true`/`false`, decimal and hex
  literals, strings with escapes, line/block comments, function/type/const/let declaration
  names and `@Annotation`s.
- `extension.js` discovers the installed compiler (`lib/compiler.js`), checks its version, starts the
  language server `orin lsp` (LSP over stdio) with `vscode-languageclient` and shows a status bar item.
  Plain JavaScript, no build step.

## Compiler discovery

No configuration is needed once Orin is installed (`docs/install.md`). When a `.or` file opens, the
extension looks for the `orin` executable in this order and uses the first one that works:

1. `orin.serverPath`, when set (empty by default). A path that does not exist or does not answer
   `--version` is reported as an error; the search does not silently continue past it.
2. Inside the orin repository (workspace has `compiler/` and `tools/orin`): `build/bootstrap/orin2`,
   `build/dev/orin`, then the `tools/orin` dev launcher. These are treated as `development` builds
   and are not version-checked (`tools/orin` rebuilds the compiler on each run).
3. `orin` on `PATH`.
4. The install locations of `install.sh`: `$ORIN_HOME/bin/orin`, `~/.orin/bin/orin`,
   `~/.orin/current/bin/orin`, `~/.local/bin/orin`, `/opt/homebrew/bin/orin`, `/usr/local/bin/orin`.

The chosen compiler is run with `--version` and checked against the range this extension supports
(`orinCompiler` in `package.json`: `0.1.0-alpha.2` or newer in the `0.1.x` series). If it is missing
or outside the range, a notification explains why and offers **Open install docs** (and **Open
settings** when nothing was found). An unrecognised version string only produces a warning.

The status bar item at the right shows the compiler version and language server state
(`Orin 0.1.0-alpha.2`, with a check, spinner, warning or error icon). Click it, or run
**Orin: Show Compiler Info**, to see the path, how it was found, the compatibility verdict and the
output of `orin doctor` in the "Orin" output channel.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `orin.serverPath` | empty | Override for the `orin` executable (run as `orin lsp`). Empty means automatic discovery. Changing it restarts the server. |
| `orin.trace.server` | `off` | LSP trace level (`off`, `messages`, `verbose`). |

Commands: **Orin: Restart Language Server**, **Orin: Show Compiler Info**, **Orin: Open Install Docs**.

## Server features

`orin lsp` serves diagnostics (E-codes with exact ranges, for every open file and the files it
imports), document symbols, completion (locals and parameters in scope, declarations, imported
names, keywords, built-ins), formatting (the canonical `orin fmt` layout), go to definition,
hover (signature or type), find references and rename, across modules. Rename is refused while the
workspace has errors, because the semantic index is then partial. See
`spec/18-developer-tooling.md`.

## Using the language server

1. Install Orin (`curl -fsSL https://raw.githubusercontent.com/orin-lang/orin-lang/main/install.sh | sh`,
   see `docs/install.md`), or inside the orin repository build the compiler with
   `./tools/bootstrap.sh` (`build/bootstrap/orin2`; the `lsp` command needs a build from stage 2 on).
2. Open a `.or` file. The extension finds the compiler itself (see "Compiler discovery"). Any other
   editor with a generic LSP client works too: command `orin`, argument `lsp`, language id `orin`,
   files `*.or`.
3. Every open document is analysed as its own entry (a missing `main` is tolerated); unsaved buffers
   are used for imported modules too.

Check it without an editor: `python3 tools/test_lsp.py` drives a freshly built `orin lsp` with real
JSON-RPC messages.

## Develop

```sh
cd editors/vscode
npm install
npm test          # grammar tokenization (vscode-textmate) + compiler discovery / version tests
npx @vscode/vsce package   # builds orin-vscode-<version>.vsix locally (never published from here)
```

To try it, open this folder in VS Code and press F5 (Extension Development Host), after
`npm install` (installs `vscode-languageclient`). `node_modules/` is not committed.
