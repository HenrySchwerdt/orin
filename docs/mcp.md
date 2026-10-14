# `orin mcp` — compiler-integrated MCP server

Implements spec 10 on top of the shared analysis services (`compiler/analysis`, ADR-0008): the same
loader/checker/semantic-index code that powers `orin lsp`. Source: `compiler/mcp/`.

```
orin mcp [--root <dir>] [--allow-exec] [--repo <dir>]
```

| Option | Meaning |
|---|---|
| `--root <dir>` | Authorized workspace root (default: cwd). Every path a client passes, and every file a project imports, must lie inside it. Prefer an absolute path. |
| `--allow-exec` | Enables `test` and `build` (they run the compiler backend, `cc` and project code). Without it they return a tool error. |
| `--repo <dir>` | Orin checkout providing `runtime/` (for linking) and `tools/run_tests.py` + `build/bootstrap/orin2` (for suites). Default: cwd. |

Transport: stdio, newline-delimited JSON-RPC (one message per line, no embedded newlines).
Protocol revision: **2025-06-18** (`initialize`, `ping`, `tools/list`, `tools/call`; notifications
are accepted and ignored; batches are not supported, they were removed in this revision).
Tool results are a single `text` content block holding compact JSON; failures set `isError: true`
with a plain-text message. No `structuredContent` is sent (it would double the tokens).

Client config example: `{"command": "orin", "args": ["mcp", "--root", "/path/to/project"]}`.

## Tools

Positions are **1-based** `line`/`column` (the same convention as the diagnostics), given as
`{"line":L,"column":C}` or `"L:C"`. Paths are relative to the root.

### `check` {entry, format?, sinceRevision?, limit?}

Type-checks the project rooted at `entry`. Diagnostics carry stable codes (`E0400`, ...).
`format`: `compact` (default; one string per diagnostic `CODE file:line:col message`) or `detailed`
(objects with `id`, end position and notes). `limit` (default 50) caps the list; `more` reports the rest.

```json
→ {"entry":"a.or"}
← {"revision":1,"errors":1,"diags":["E0400 a.or:5:18 expected `int`, found `string`"]}
```

Revisions: the server keeps a snapshot per `(entry, project fingerprint)`. An unchanged project
keeps its revision id; any change to a file the project reads gets a new one. Diagnostic identity is
content-stable: `hash(code, file, message, nth occurrence)` — line shifts do not change it. With
`sinceRevision` equal to a revision this server returned for the same entry, the answer is a delta:

```json
→ {"entry":"a.or","sinceRevision":1}
← {"revision":2,"base":1,"resolved":["E0400 a.or:5:18 expected `int`, found `string`"],"added":[],"remaining":0}
```

An unknown base (other entry, evicted — the last 32 snapshots are kept —, or never issued) returns the
full snapshot plus `"note":"base revision unknown ..."`; deltas are never guessed.

### `inspect` {symbol | module | file+position, entry?, includeSource?}

No source text unless `includeSource: true`.

* `symbol`: `"name"`, `"Type.member"` or a built-in API (`"Array.find"`, `"string.split"`,
  `"Option.unwrap"`, ...). Built-ins come from a small table (signature, failure semantics, whether it
  mutates, cost, allocation, example); `Array.find` is flagged `planned` because the self-hosted
  compiler does not implement it yet. Project symbols resolve in the program rooted at `entry`:
  `{"name","kind","sig","at":"file:line:col","exported","in","mutates"}` — `mutates` (methods only) is
  the checker's inferred receiver mutability. Interfaces (ADR-0019) have kind `interface` with
  `"implementedBy":["Circle at shape.or:7:7", ..]`; a class has `"implements":["Shape", ..]`; an interface
  method is a `method` whose `in` is the interface. A function, method or constructor also has
  `"effects":{"pure":false,"effects":[{"operation":"Fs.ReadFile","direction":"INPUT","grant":"FsGrant","evidence":"MAY",
  "path":[{"function":"store::reload","span":{...},"route":"direct"},{"function":"store::loadConfig",...}]}],"callbacks":[]}`:
  its inferred, transitive effect summary ([capabilities.md](capabilities.md), the same analysis as `orin effects`, the OSIG
  `MAY_PERFORM` edges and the LSP hover). `evidence` is MUST / MAY / UNKNOWN, `path` the call chain to the primitive call,
  `callbacks` the parameters whose function values it calls (its effects then depend on the arguments). Omitted when the
  program does not type-check.
* `module`: a file path (or unit name) in the program rooted at `entry` (default: the module itself):
  ```json
  ← {"module":"a","file":"a.or","exports":["function double(n: int): int"],"imports":[],"importedBy":["m"]}
  ```
  A module of the program (not std library code) also has `"effects"`: what the code written in the module may perform, transitively
  (the module row of `orin effects`), each with its witness path.
* `file` + `position`: the symbol at the position, else the type of the expression there.

### `edit` {kind:"rename", file, position, newName, entry?, apply?}

Computes the rename edit list from the semantic index (all uses, across files of the program rooted at
`entry`, default `file`), then re-analyses the edited program in memory: `valid` is false if it would
have more errors than before. Nothing is written unless `apply: true`, the result is valid and every
touched file is inside the root.

```json
→ {"kind":"rename","file":"a.or","position":"1:20","newName":"twice","entry":"m.or"}
← {"symbol":"double","newName":"twice","valid":true,"applied":false,"errorsBefore":1,"errorsAfter":1,"edits":["a.or:1:17","m.or:1:10"]}
```

Every edit replaces the identifier of length `len(symbol)` at the listed position with `newName`.

### `test` {entry? | suite?, filter?, unit?} — needs `--allow-exec`

* `entry` with `unit: true`: runs the `@Test` functions of that program or package, exactly like
  `orin test` (docs/testing.md; one process per test, 10 s timeout each, `filter` = substring of the test
  id). The result is the report of `orin test --format=json`: `{"ok":false,"total":2,"passed":1,"failed":1,
  "filtered":0,"tests":[{"id":"u.ok","status":"pass",...},{"id":"u.bad","status":"fail","reason":"trap",
  "stderr":"trap: assertEq failed: ..."}],"warnings":[]}`. A program that does not compile returns the
  diagnostics like `build`; a project that reads files outside the root is refused before anything runs.
  The build directory is a fresh `/tmp/orin-test-N`, removed afterwards.
* `entry`: compiles and runs one program (10 s timeout) and compares stdout with `<name>.out`
  (or `expected.out` next to `main.or`); honours a `// exit: N` first line.
  `{"passed":true,"exit":0}`; on failure `why`, `stdout`, `stderr` (truncated).
* otherwise runs the conformance runner (`suite` `default|next|all`, `filter`):
  `{"passed":78,"failed":0,"ok":true}` plus `failures` (names, at most 30) when any.

### `build` {entry, out, binary?} — needs `--allow-exec`

Compiles through the MIR pipeline to C at `out` (`@Test` functions are type-checked and erased); with `binary` also links it with `cc` against
`<repo>/runtime`. `{"ok":true,"c":"build/main.c","bytes":58213,"binary":"build/main"}`; compile
errors return `{"ok":false,"errors":N,"diags":[...]}` in the `check` compact format.

### `graph` {entry, full?, out?}

OSIG snapshot (`docs/osig.md`, ADR-0023) of the checked program rooted at `entry` (a file or a package
directory): symbols, modules, `CALLS` edges with `MUST`/`MAY`/`UNKNOWN` evidence, imports, implements,
type references, contract clauses. Same engine as `orin graph`. Returns the summary
`{"schema","package","hash","nodes","edges"}`; `full: true` adds `"snapshot"` (the deterministic
snapshot text); `out` also writes it to a file inside the root. A project with errors is a tool error
carrying the rendered diagnostics.

```json
→ {"entry":"shop"}
← {"schema":"osig/0.2","package":"shop","hash":"h62:7467802e45ac2dcd","nodes":23,"edges":44}
```

### `diff` {base, head, format?, out?}

Compares two OSIG snapshots (`base`, `head`: package directory, entry `.or` file or a snapshot `.json`
written by `graph`): changed / added / removed symbols, added / removed call, import, implements and
type-reference edges, **heuristic** rename candidates (never identity), and for every changed symbol and
every new call the entry points that reach it with the explaining path and per-hop evidence. `format`:
`json` (default, `osig-diff/0.2`), `text` or `html` (one self-contained file); `out` writes the report
inside the root and returns `{"written","differences"}`. Same engine as `orin diff`.

```json
→ {"base":"acme-base","head":"acme-head"}
← {"schema":"osig-diff/0.2","differences":true,"summary":{"added":4,"removed":1,"changed":1,...},"changedSymbols":[...],"possibleRenames":[{"heuristic":true,...}],"newCallPaths":[...],...}
```

## Security model

* Reads and writes are confined to `--root` (lexical normalisation; **symlinks are not resolved**, so a
  symlink inside the root can point out of it — run with a root you trust or inside a sandbox).
* A project that imports a file outside the root is refused for `check`/`inspect`/`edit`/`build`/`graph`/`diff`.
* `test`/`build` run `cc` and project code with the server's privileges: they are off unless
  `--allow-exec` is given. Even then the process is not sandboxed; run the server in a container for
  untrusted projects. Temporary artifacts go to `<root>/.orin-mcp/`.
* `edit` writes only with `apply: true`; no tool can touch FFI machinery. `check` reports errors only: `@Deprecated` warnings (W0440) are not listed.

## Token economy

* Compact JSON, no whitespace, no echo of the request, no source text unless asked.
* A diagnostic is one line (`CODE file:line:col message`, ~15–25 tokens); stable ids and end positions only in
  `detailed`.
* The edit loop `check → fix → check{sinceRevision}` returns only what changed; a clean re-check is
  `{"revision":3,"base":2,"resolved":[...],"added":[],"remaining":0}`.
* `inspect` answers "what is the signature / who imports this" without the agent reading files;
  `edit` returns locations instead of file contents.
* Measured payloads (bytes of the `text` block): clean check 25, one-error check ~90, module
  inspect ~140, built-in API entry ~330, rename dry run ~170. `tools/list` is ~3.8 KB (once per session).

## Limitations

* Whole-program re-analysis on every call (no incremental compilation yet); revisions are
  content fingerprints, not edit-aware.
* Entries are analysed as their own program (a library entry gets a synthetic `main`, as in the LSP).
* The checker stops at the first error per function body, so a function contributes at most one diagnostic.
* Only `rename` is implemented in `edit`; `inspect(annotation)` and `orin memory --report` are not available yet.
* Numbers in JSON are integers (Orin-B has no floats).
