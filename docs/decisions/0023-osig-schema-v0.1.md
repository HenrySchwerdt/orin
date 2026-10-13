# ADR-0023: OSIG schema v0.1 (Orin Software Intelligence Graph)

Status: accepted (2026-10-13). Implements vision ticket 1 and, with it, tickets 3, 5 and 6
(`docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md` §4, §16; ADR-0020 D2). User documentation: `docs/osig.md`.
Source: `compiler/analysis/osig*.or`, call sites recorded in `compiler/check/index.or`.

## Context

ADR-0020 D2 fixed that the OSIG is the existing semantic engine (ADR-0008) grown, not a second analysis:
nodes and edges come from the checker, HIR and semantic index of one compile; `orin graph` exports it and
`orin diff` generalises `orin api --check`. This ADR fixes the first schema, what is actually produced
today, and the rules that keep it honest. It deliberately contains only what the compiler can state now.

## Decisions

**1. Schema id and versioning.** The snapshot carries `"schema": "osig/0.1"`. The version is independent of
the compiler version (no compiler version appears in a snapshot). `0.x` minor versions are additive (new
node kinds, edge kinds or fields; readers ignore what they do not know); a breaking change bumps the
major (`osig/1.0`). `orin diff` reads every `osig/0.*` snapshot and refuses other majors.

**2. Node kinds produced now.** `Package`, `Module`, `Function`, `Method` (including `constructor` and
interface methods), `Class`, `Interface`, `Record`, `Union`, `Alias`, `Const`, `Field`, `Variant`,
`Contract` (one node per contract clause, ADR-0012: `requires`, `ensures`, `invariant`, `decreases`,
`rule`), and the single pseudo node `Unknown` (target of calls through function values; present only when
such a call exists). Locals and parameters are not graph nodes. Vision node kinds not listed here
(`Feature`, `Effect`, `CapabilityGrant`, `DataSource`, ...) are produced by later phases; they will be
added as minor versions.

Node attributes: `id`, `kind`, `name`, `module`, `owner` (containing node), `sig` (the rendered signature
as the semantic index and `orin api` render it, e.g. `mut method reset(): void`; for a `Contract` the
clause text), `exported`, `entry` (entry point: `main`, exported functions, exported public methods and
constructors; not interface methods), `span`.

**3. Edge kinds produced now.** Each edge has `kind`, `src`, `dst`, `evidence`, `via`, `span`.

| Kind | Meaning | Evidence |
|---|---|---|
| `DEFINES` | Package to Module, Module to its top-level symbols, Class/Interface to methods, Union to variants | MUST |
| `HAS_FIELD` | Record/Class to Field | MUST |
| `HAS_CONTRACT` | symbol to one of its contract clauses (class invariants hang off the class) | MUST |
| `IMPORTS` | Module to Module (between different modules of the package; `std:` imports are not edges yet) | MUST |
| `IMPLEMENTS` | Class to Interface (`implements`, ADR-0019) | MUST |
| `REFERENCES_TYPE` | the innermost enclosing declaration (function, method, field, type) to the type it mentions (record, class, union, alias, interface; a variant counts as its union); one edge per (source, target) | MUST |
| `CALLS` | see below | see below |

`CALLS` edges come from the typed HIR of the same compile (`SemanticIndex.calls`, one `CallSite` per call):

| Source construct | Target | Evidence | `via` |
|---|---|---|---|
| call of a function | the function | MUST | `direct` |
| call of a method (static or on a class value), `new C(..)` | the method / constructor (the class when it has no explicit constructor) | MUST | `method`, `constructor` |
| call through an interface value (`s.area()`) | the **interface method** | MUST | `virtual` |
| call of an interface method through a bounded type parameter (`x.area()` with `T extends Shape`) | the interface method | MUST | `bound` / `virtual` |
| the same call, expanded | the method of **every class that `implements` the interface** | MAY | `impl` |
| call inside a closure / arrow function body | the callee, attributed to the **enclosing function** (the closure runs only if called) | MAY | as above |
| a function used as a value (`const f = double`) | the function | MAY | `value` |
| call of a function value / closure | `~unknown` | UNKNOWN | `indirect` |

Evidence classes follow vision §4.4: `MUST` holds in every execution that reaches the source (static call
in the body), `MAY` is a conservative possible edge, `UNKNOWN` marks a boundary the analysis cannot see
through. **Nothing the analysis cannot resolve statically is ever `MUST`.** Edges are unique per
(`kind`, `src`, `dst`, `evidence`, `via`); `span` is the first occurrence in source order (line shifts
therefore do not change edge identity).

**4. Absence of an edge is not proof of absence.** A function that is only reachable through function
values appears with a `MAY` edge at the point where it was turned into a value and with `UNKNOWN` edges
where function values are called; the graph says nothing about *which* value reaches which call. Calls
into the std prelude/built-ins, FFI, `std:` modules and anything outside the loaded package are not
edges. Field reads/writes, data flow and effects are not modelled yet (phases 2/3). Every consumer (the
diff report, MCP, agents) must present "no path found" as "no path in the analysed edges", never as a
guarantee; `orin diff` prints this note in every report.

**5. Stable symbol ids (ADR-0020 D2).** `id = <package>:<module>::<path>` where `package` is the
`orin.toml` package name (`_` without manifest), `module` the module id (directory of the nearest
`module.or`; `(root)` for the root module) and `path` the symbolic path inside the module: `Name`,
`Class.method`, `Class.field`, `Union.Variant`; a contract clause is `<owner>@<kind>#<n>` (n counts the
clauses of that kind on the owner); `Module` is `<package>:<module>`, `Package` is `<package>`. The id
contains **no types and no file names** (except to disambiguate two private top-level symbols of the same
name in different files of one module: `~<file>` is appended), so a signature change keeps the id and is
reported as a *change*, not as remove + add. A rename or a move changes the id by construction; the diff
cannot know it was a rename (decision 8). The API snapshot (`orin api`) keys on the full signature line;
OSIG keys on the path and carries the signature as an attribute, which is what makes signature
changes first-class.

**6. Source spans.** `span = {file, line, col, endLine, endCol}`, 1-based; columns count bytes. `file` is
relative to the source root of the package (the directory of the manifest entry, `src/` by default;
the entry file's directory without manifest), `/`-separated. Never absolute. `Package`, `Module` and
`Unknown` nodes have an empty span (`file: ""`). An edge span is the call site / import / type mention;
a node span is the whole declaration.

**7. Deterministic serialisation and hash.** Nodes sorted by `id` (byte order), edges sorted by the
string `kind|src|dst|evidence|via`; no timestamps, no absolute paths, no compiler version, no
environment. The text has a fixed layout (one node and one edge per line, compact JSON values) so
snapshots diff line by line. Two runs over the same sources are byte-identical regardless of the working
directory or where the package is checked out. `hash` is a 62-bit fingerprint of schema, package, nodes
and edges (two independent 31-bit polynomial hashes), printed as `h62:<16 hex>`. It is an equality /
tamper-evidence check for snapshot files (`orin diff` recomputes it and refuses a mismatching file), **not
a cryptographic digest**; signed, collision-resistant evidence belongs to `.orcert` (vision phase 7) and
will use a real hash then. Because spans are part of the hash, a pure line shift changes the hash; the
diff report, which compares content, reports nothing in that case.

**8. `orin diff` semantics.** The input is two OSIG snapshots (from package dirs, entry files or `.json`
snapshot files). Symbols are matched by id. Reported: added, removed and changed symbols (changed =
`signature`, `mutability` (the inferred `mut` of a method changed, the rest of the signature did not),
`visibility`, `kind`, `entry-point`, `contract` (clause text of a `Contract` node)); added and removed
`CALLS`, `IMPORTS`, `IMPLEMENTS` and `REFERENCES_TYPE` edges (structural edges follow from the symbol
lists and are not repeated). **Renames and moves are a separate heuristic class**: a removed and an added
symbol of the same kind, with the same signature once the symbol's own name is erased and the same owner
(or an owner that was itself removed/added), are listed as *possible renames* with a confidence
(`high` unique match with identical callees, `medium` unique match, `low` ambiguous) and the basis. They
are never merged into the symbol lists and never described as identity: the removed and added symbols stay
listed. **Reverse impact** walks the head graph backwards from every changed symbol over `CALLS` and
`REFERENCES_TYPE` edges (and from a field, variant or contract clause to its owner) to the nearest entry
points (at most 5 per target, breadth first, deterministic) and prints the path with the evidence of every
hop and the weakest evidence of the whole path. The same walk explains **new call paths** (for every added
`CALLS` edge: the entry points of the head graph that reach its caller, followed by the new edge) and
removed ones (in the base graph). Findings per section are capped at 100; the report says when it
truncated. Report formats: text, JSON (`osig-diff/0.1`), one self-contained HTML file.

**9. `orin api` stays.** `orin api [--check]` keeps its text format and behaviour (its tests are
unchanged). It remains the lean, human-reviewed public-API contract; `orin diff` is the general mechanism.
They share the semantic index and the signature rendering; `orin api` is not re-implemented on OSIG in
this step (a later step may express the API snapshot as the exported-symbol projection of an OSIG).

## Alternatives considered

- **Signature in the id** (as the API snapshot does): a signature change would be remove + add and every
  edge would change identity. Rejected for the graph; kept for the API snapshot.
- **Analysing source text for calls**: duplicates the checker and is wrong for method/interface
  resolution. Rejected (D2): calls are recorded where the HIR resolves them.
- **Hash with SHA-256 in the compiler**: Orin-B has no bit operations yet; a weak hash that is honestly
  labelled is more useful now than a long implementation that adds TCB. Replaced when `.orcert` needs it.
- **Edge per call site** (with counts): makes diffs noisy under refactoring. One edge per
  (kind, src, dst, evidence, via) with the first span.

## Consequences

- `SemanticIndex` gains `calls: CallSite[]` (`hir/index.or`), recorded in the HIR walk of `check/index.or`;
  every constructor of a `SemanticIndex` (tests) sets it.
- `orin graph`, `orin diff` and the MCP tools `graph` / `diff` share one engine (`compiler/analysis`).
- Later phases extend the schema additively: effects (phase 2) add `Effect`/`CapabilityGrant` nodes and
  `REQUIRES_CAPABILITY` edges; lineage (phase 3) adds `READS`/`WRITES`/`MAY_FLOW_TO`; feature manifests
  (ticket 4) add `Feature` nodes and `IMPLEMENTS_REQUIREMENT`. The impact walk will then follow them.
- Known precision limits (documented in `docs/osig.md`): no points-to analysis (function values), no
  flow/context sensitivity, one `implements` expansion per interface call (every implementer, even if only
  one is ever converted to the interface), no edges into `std:`/built-ins/FFI, a generic function's calls are
  attributed once to the generic declaration (not per instance).
