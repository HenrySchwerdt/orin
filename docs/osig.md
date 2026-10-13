# OSIG: `orin graph` and `orin diff`

The Orin Software Intelligence Graph is the semantic engine's view of one compile: symbols, modules,
calls, imports, implementations, type references and contract clauses, each with a stable id, a source
span and (for edges) an evidence class. `orin graph` exports it, `orin diff` compares two of them and
explains the difference. Design and rules: [ADR-0023](decisions/0023-osig-schema-v0.1.md) (schema),
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

## Snapshot shape (`osig/0.1`)

```json
{
"schema": "osig/0.1",
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
`REFERENCES_TYPE`, `CALLS`.

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
4. **added / removed edges**: `CALLS`, `IMPORTS`, `IMPLEMENTS`, `REFERENCES_TYPE`.
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

The JSON report has the keys `changedSymbols`, `addedSymbols`, `removedSymbols`, `possibleRenames`
(each with `"heuristic": true`), `addedEdges`, `removedEdges`, `newCallPaths`, `removedCallPaths`,
`impact`, plus `summary`, `differences` and the two hashes. A run without differences reports
`no differences` (text), `"differences": false` (JSON) or "No differences." (HTML). A comment or blank
lines that only shift line numbers are not differences.

The HTML report is a single file: inline CSS (light/dark), no scripts, no external assets. Sections:
summary, changed symbols, added/removed symbols, possible renames, new and removed call paths with the
explaining path, added/removed edges, impact on entry points.

## MCP

`orin mcp` exposes `graph {entry, full?, out?}` and `diff {base, head, format?, out?}` over the same engine
(`docs/mcp.md`). Paths must be inside the server root.

## Limits (read before trusting a report)

- **Absence is not proof.** A missing edge or path means "not found in the analysed edges". Calls through
  function values are `UNKNOWN` (the target is not known; no points-to analysis), a function used as a
  value is a `MAY` edge from the place that created the value, and the graph does not connect the two. A
  function reachable only through function values can therefore be missing from an impact list.
- **Interface calls over-approximate.** A call through an interface gets a `MAY` edge to every class that
  `implements` it, whether or not that class is ever converted to the interface at that point.
- **Closures:** calls inside a closure are attributed to the enclosing function as `MAY` edges (they run
  only if the closure is called).
- **Generics:** calls inside a generic function are attributed to the generic declaration, once.
- **Not modelled yet:** std/built-in calls, FFI, field reads/writes, data flow, effects and capabilities,
  `std:` imports as edges. They arrive with phases 2 and 3 as additive schema versions.
- **Renames are guesses.** Same-signature matching misses a rename with a signature change and can
  pair unrelated symbols that look alike; that is why the class is separate and labelled.
- **Signature text:** the `sig` attribute is the rendered declaration; it does not know about
  semantic equivalence (a reordered record field is a signature change).
- The hash is not a security digest. Reports cap each section at 100 findings and say so.
- Programs must type-check; a type error is reported as a diagnostic instead of a graph.
