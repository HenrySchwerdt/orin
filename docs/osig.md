# OSIG: `orin graph` and `orin diff`

The Orin Software Intelligence Graph is the semantic engine's view of one compile: symbols, modules,
calls, imports, implementations, type references and contract clauses, each with a stable id, a source
span and (for edges) an evidence class. `orin graph` exports it, `orin diff` compares two of them and
explains the difference. Design and rules: [ADR-0023](decisions/0023-osig-schema-v0.1.md) (schema, versioning),
[ADR-0020](decisions/0020-verifiable-software-roadmap.md) D2 (it is the existing engine grown, not a
second one). Source: `compiler/analysis/osig*.or`.

## Commands

```
orin graph <entry.or | package-dir> [-o out.json]
orin diff --base <package-dir | entry.or | snapshot.json> --head <package-dir | entry.or | snapshot.json>
          [--format=text|json|html] [--link-base <url>] [-o out] [--exit-code]
```

- `graph` type-checks the program (std prelude not loaded, like `orin api`) and prints the snapshot, or
  writes it to `-o`. Compile errors are printed as diagnostics and the exit code is 1.
- `diff` builds (or reads) the two graphs, and prints the report. Default format `text`. The exit code
  is 0 whenever the report was produced (report only, so CI can attach it without failing); with
  `--exit-code` it is 1 if the graphs differ. A snapshot file with a wrong hash is refused.
- `--link-base URL` makes the HTML `path:line` references links `URL/<file>#L<line>` (for a repository
  browser); without it they are plain text.
- Typical use on a pull request: check out the base next to the head and run
  `orin diff --base ../base/pkg --head pkg --format=html -o osig-diff.html`
  (see the `ci` workflow, step "OSIG diff report"). `orin diff` of the compiler itself takes a few seconds.

`orin api --check` is unchanged: it stays the small, reviewed public-API contract (full signature lines
of exported symbols). `orin diff` covers everything else (call/import/type edges, impact).

## Snapshot shape (`osig/0.3`)

```json
{
"schema": "osig/0.3",
"package": "demo",
"hash": "h62:0123456789abcdef",
"nodes": [
  {"id":"demo:shapes::Circle.area","kind":"Method","name":"area","module":"shapes","owner":"demo:shapes::Circle","sig":"method area(): int","exported":true,"entry":true,"span":{"file":"src/shapes/shapes.or","line":8,"col":3,"endLine":8,"endCol":50}}
],
"edges": [
  {"kind":"CALLS","src":"demo:shapes::describeFirst","dst":"demo:shapes::Circle.area","evidence":"MAY","via":"impl","span":{"file":"src/shapes/shapes.or","line":30,"col":10,"endLine":30,"endCol":18}}
]
}
```

One node and one edge per line (so snapshots diff line by line). Golden example:
`tests/osig/demo.graph.json` (package `tests/osig/demo`: modules, classes, an interface, generics,
closures, contract clauses).

**Node kinds:** `Package`, `Module`, `Function`, `Method` (also `constructor` and interface methods),
`Class`, `Interface`, `Record`, `Union`, `Alias`, `Const`, `Field`, `Variant`, `Contract`, `Unknown`.
`entry` marks entry points: `main`, exported functions, exported public methods and constructors.

**Edge kinds:** `DEFINES`, `HAS_FIELD`, `HAS_CONTRACT`, `IMPORTS` (module to module), `IMPLEMENTS`,
`REFERENCES_TYPE`, `CALLS`, `PERFORMS_IO` (a primitive I/O call site, ADR-0027), `MAY_PERFORM` (the transitive effect summary,
`osig/0.2`, below).

**Schema history** (ADR-0023 versioning: additive changes bump the minor version, readers ignore what they do not know, a
reader refuses another major): `osig/0.1` the first schema; `osig/0.2` adds the edge kind `MAY_PERFORM` and the edge field
`next` (present on `MAY_PERFORM` edges only, so every other edge line is unchanged); `osig/0.3` adds the node field `doc` (the
rendered `/** ... */` documentation comment attached to the declaration, Markdown with `@tags`, see `analysis/doccomments.or`;
written only when the declaration has one, so every other node line is unchanged). `orin diff` reads every `osig/0.*`
snapshot; against a snapshot older than 0.2 the effect sections are skipped ("not compared").

**Effects (`MAY_PERFORM`, ADR-0037 D2, [capabilities.md](capabilities.md)):** for every function, method, constructor and class
(field initialisers) one edge per primitive effect it may perform *transitively*, to the compiler-owned `Effect` node
(`~io:Fs.ReadFile`, `sig` = `INPUT; grant: FsGrant`), or to `~unknown` for an effect whose target is not known. `via` is the
direction (`INPUT` / `OUTPUT` / `CONTROL`), for `~unknown` the kind (`Unknown.FunctionValue`, `Unknown.Callback`,
`Unknown.Interface`, `Unknown.Unresolved`). `evidence`: `MUST` a primitive call written in the function's body, `MAY`
inherited / in a closure / through an implementation, `UNKNOWN` for `~unknown`. `span`: the call in the function's body that
starts the explanation path (the primitive call itself for MUST). `next`: the function the effect is inherited from ("" for
a MUST effect, or when only library code lies between); following `next` along the edges with the same `dst` and `via`
reconstructs the explanation path inside the snapshot, which `orin diff` does. A pure function has no `MAY_PERFORM` edge; every
`PERFORMS_IO` edge has a `MAY_PERFORM` edge from the same function; the summaries are closed under `CALLS` edges
(`tools/test_effects.py` asserts both on four programs). Effect nodes exist for every effect that occurs, also one that only
library code performs.

**Evidence:** `MUST` (static call/definition in the body), `MAY` (possible: inside a closure body, a
function used as a value, an implementation of an interface method that an interface call may reach),
`UNKNOWN` (call of a function value; target `~unknown`). `via` for calls: `direct`, `method`,
`constructor`, `virtual` (call through an interface value: the interface method), `bound` (through a
bounded type parameter), `impl` (MAY edge to an implementing method), `value`, `indirect`.

**Ids:** `<package>:<module>::<path>`, e.g. `shop:users::User.describe`, `demo:(root)::main`; contract
clauses `<owner>@requires#0`. No types in the id: a signature change keeps the id. A rename changes it.

**Spans:** 1-based line/column (columns in bytes), file relative to the package source root, never
absolute. **Determinism:** nodes sorted by id, edges by `kind|src|dst|evidence|via`; no timestamps, no
compiler version; two runs (from any directory, any checkout location) are byte-identical.
**Hash:** `h62:` + 62-bit fingerprint of the body; detects edited/truncated snapshots; not a
cryptographic digest.

## The diff report

Sections (text, JSON `osig-diff/0.1` and HTML carry the same content):

1. **changed symbols**: same id, different `signature`, `mutability` (inferred `mut` of a method),
   `visibility`, `kind`, `entry-point` or `contract` text, with before/after.
2. **added / removed symbols**.
3. **possible renames (HEURISTIC)**: a removed and an added symbol of the same kind with the same
   signature once the name is erased and the same owner. Confidence `high` (unique, same callees),
   `medium` (unique), `low` (ambiguous). Never asserted as identity: the symbols stay listed as removed
   and added. A rename combined with a signature change is not detected.
4. **added / removed edges**: `CALLS`, `IMPORTS`, `IMPLEMENTS`, `REFERENCES_TYPE` (`MAY_PERFORM` has its own section, 7).
5. **new / removed call paths**: for every added `CALLS` edge, the entry points of the head graph that
   reach its caller, as a path with the evidence of every hop (breadth first, shortest, at most 5 per
   edge). Removed calls are explained in the base graph.
6. **impact**: for every changed symbol, the entry points that reach it (over calls and type
   references; from a field, variant or contract clause via its owner), with the path.

Example (text, from `tests/osig/accept`):

```
changed symbols:
  [signature] Function acme:orders::checkout  (src/orders/orders.or:7)
      - function checkout(qty: int): int
      + function checkout(qty: int, express: bool): int
possible renames (HEURISTIC, not proven identity; ...):
  ? Function acme:orders::applyDiscount => acme:orders::applyRebate  confidence medium; basis: same signature modulo name
new call paths (entry points of head that reach the new call):
  CALLS [MUST] acme:audit::record -> acme:audit::sink  (src/audit/audit.or:6)
    path [MUST]:
      entry acme:(root)::main  (src/main.or:3)
        -> CALLS/direct [MUST] acme:orders::checkout  (src/main.or:4)
        -> CALLS/direct [MUST] acme:audit::record  (src/orders/orders.or:8)
        -> CALLS/direct [MUST] acme:audit::sink  (src/audit/audit.or:6)  <- NEW
```

7. **effect changes** (`osig/0.2` snapshots on both sides): the effects a *module* gained or lost (the union over its functions,
   abstract interface methods excluded), and per *function* every effect that is new (`added`), gone (`removed`) or has
   another evidence class (`evidence`, with the old one), each with the explanation path in the graph where the effect exists
   (the head for new effects, the base for removed ones). For a new effect that the function performs itself, the entry
   points of the head that reach the function: everything that now performs the effect. Findings are capped like the others.

```
effect changes (transitive primitive effects; new or removed per module and function):
  module (root):
    - Fs.WriteFile OUTPUT
  module store:
    - Fs.WriteFile OUTPUT
  module util:
    + Console.Write OUTPUT
  - app:(root)::main  Fs.WriteFile OUTPUT [MAY]  (in base)
      app:(root)::main  (src/main.or:13)
      -> app:store::saveConfig  (src/store/store.or:11)
  - app:store::saveConfig  Fs.WriteFile OUTPUT [MUST]  (in base)
      app:store::saveConfig  (src/store/store.or:11)
  + app:util::fact  Console.Write OUTPUT [MUST]
      app:util::fact  (src/util/util.or:3)
      reached from entry point app:util::fact [MUST]
      reached from entry point app:(root)::main [MAY]
```

The JSON report has the keys `changedSymbols`, `addedSymbols`, `removedSymbols`, `possibleRenames`
(each with `"heuristic": true`), `addedEdges`, `removedEdges`, `newCallPaths`, `removedCallPaths`,
`impact`, `effectsComparable`, `effectChanges` (per function: `kind`, `function`, `module`, `operation`, `direction`, `evidence`,
`was`, `span`, `path`, `reach`), `moduleEffects` (per module: `added`, `removed`), plus `summary` (with `effectsAdded` /
`effectsRemoved`), `differences` and the two hashes; the report schema is `osig-diff/0.2`. A run without differences reports
`no differences` (text), `"differences": false` (JSON) or "No differences." (HTML). A comment or blank
lines that only shift line numbers are not differences.

The HTML report is a single file: inline CSS (light/dark), no scripts, no external assets. Sections:
summary, changed symbols, added/removed symbols, possible renames, new and removed call paths with the
explaining path, added/removed edges, impact on entry points.

## MCP

`orin mcp` exposes `graph {entry, full?, out?}` and `diff {base, head, format?, out?}` over the same engine
(`docs/mcp.md`); `inspect` returns the effect summary of a symbol or module (same analysis as the `MAY_PERFORM` edges).
Paths must be inside the server root.

## Limits (read before trusting a report)

- **Absence is not proof.** A missing edge or path means "not found in the analysed edges". Calls through
  function values are `UNKNOWN` (the target is not known; no points-to analysis), a function used as a
  value is a `MAY` edge from the place that created the value, and the graph does not connect the two. A
  function reachable only through function values can therefore be missing from an impact list.
- **Interface calls over-approximate.** A call through an interface gets a `MAY` edge to every class that
  `implements` it, whether or not that class is ever converted to the interface at that point.
- **Closures:** calls inside a closure are attributed to the enclosing function as `MAY` edges (they run
  only if the closure is called).
- **Generics:** calls inside a generic function or a generic-class method are attributed to the generic declaration, once.
  A generic class is one `Class` node (`sig` shows `class Stack<T>`); its instantiations are not symbols (ADR-0026).
- **Primitive I/O (ADR-0027):** every call site of a std I/O primitive (`readFile`, `File.write`, `shell`, `nowMillis`,
  `console.log`, ...) and of the std scope functions (`withFile`, `useUnder`, `useFs`, ...) becomes a `PERFORMS_IO`
  edge from the enclosing function to a compiler-owned `Effect` node (`~io:Fs.ReadFile`, `sig` = `INPUT; grant:
  FsGrant`); the edge's `via` is the direction `INPUT` / `OUTPUT` / `CONTROL`, evidence `MUST` for a direct call
  (`MAY` inside a closure). `console.*` and `exit` are `ambient` (they need no grant). These are call sites, not effect
  summaries: a function that only *calls* one that performs I/O has no edge of its own (transitive inference is Stage B),
  and a call through a function value is `~unknown`, so an absent edge never proves the absence of I/O.
- **Tasks (ADR-0017 stage 0):** the `std:task` functions are events like the scope functions: `spawn` / `spawnDo` / `parallelMap` are `~io:Task.Spawn`
  (`CONTROL`, grant `ambient`), `spawnFs` / `spawnProcess` / `spawnStdio` / `spawnClock` are `~io:Task.SpawnFs` ... (`CONTROL`, naming the delegated
  grant family), `scope*` and `TaskHandle.join` are `~io:Task.Join` (`CONTROL`), `channel` is `~io:Channel.Open` (`CONTROL`), `Sender.send` is
  `~io:Channel.Send` (`OUTPUT`) and `Receiver.recv` is `~io:Channel.Receive` (`INPUT`). What a task body does is attributed to the enclosing
  function (`MAY`, like every closure). Edges between tasks are the send / receive effects themselves: every sender and every receiver of any
  channel meets at the same effect node; matching a send to its receivers per channel is a later analysis. Test: `tests/osig/tasks`.
- **Not modelled yet:** transitive effects, FFI, field reads/writes, data flow, grant chains and runtime events,
  summaries: a function that only *calls* one that performs I/O has no `PERFORMS_IO` edge of its own; its transitive summary
  is the `MAY_PERFORM` edges (Stage B, `osig/0.2`). An absent `PERFORMS_IO` edge never proves the absence of I/O.
- **Effect summaries over-approximate** (ADR-0037 D2; [capabilities.md](capabilities.md) has the argument): a function value of
  unknown origin, an interface method without implementation and an unresolved call are `Unknown.*` effects, never pure;
  closures are accounted for the function that creates them; an interface call is the union over all declared
  implementations. They say what may be *done*, per operation family, not on which resource, and not FFI / native code.
- **Network (ADR-0033):** `Net.Bind` (CONTROL), `Net.Accept` (INPUT), `Net.Connect` (CONTROL; also name resolution),
  `Stream.Read` (INPUT), `Stream.Write` (OUTPUT; also half-close), `Net.Narrow` (CONTROL) for the primitives and the
  `std:net` functions that wrap them (`useListener`, `useAccepted`, `useConnection`, `recv`, `sendAll`, `useListen`, ...).
- **Not modelled yet:** FFI, field reads/writes, data flow, grant chains and runtime events, resource identity,
  `std:` imports as edges. They arrive with phases 2 and 3 as additive schema versions.
- **Renames are guesses.** Same-signature matching misses a rename with a signature change and can
  pair unrelated symbols that look alike; that is why the class is separate and labelled.
- **Signature text:** the `sig` attribute is the rendered declaration; it does not know about
  semantic equivalence (a reordered record field is a signature change).
- The hash is not a security digest. Reports cap each section at 100 findings and say so.
- Programs must type-check; a type error is reported as a diagnostic instead of a graph.
