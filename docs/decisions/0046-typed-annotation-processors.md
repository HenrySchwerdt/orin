# ADR-0046: User-defined annotations and pure annotation processors

Date: 2026-10-16. Status: **implemented** (slices S1-S6; the LSP/MCP/OSIG expansion of generated code is listed under "Not done" in the "As built" notes of S4 and S5 and in docs/known-limitations.md).
Related: spec/05-annotations-and-metaprogramming.md, ADR-0012 (contract clauses), ADR-0016 (1.0 scope, amended
here), ADR-0024 (built-in annotations), ADR-0027 (capabilities), ADR-0044 (OX, `@Sealed`), ADR-0020/0023 (OSIG).
Supersedes the first draft of this ADR (PR #109), whose three-capability split, safety rules and alternatives are kept.

## Context

Today `compiler/syntax/ast.or` knows only `ATest | ADeprecated | AInline | ASealed` and `compiler/syntax/parser.or`
rejects every other `@Name` with E0408. Spec 05 promises typed, deterministic compile-time generation (route tables,
codecs, validation, documentation metadata) without runtime reflection, but left the definition syntax, the
execution model, hygiene and ordering open. `std:json` already notes a codegen-based `parse<T>` that waits for this.

**Owner decision (2026-10-16):** user-defined annotations and processors are part of the language scope before 1.0
("dann sind wir so gut wie sprach feature complete"). This amends ADR-0016 (see the last section). The feature is
additive: programs without user annotations compile to byte-identical C and LLVM IR.

## Decision overview

1. **Annotation definitions** are ordinary record types marked with the built-in `@Annotation`. A use is a typed,
   constant-only application. Without a processor an annotation is *metadata*: it is checked, kept in the semantic
   index, OSIG, hover, MCP and the API snapshot, and has no effect on generated code.
2. **Processors** are ordinary, verified-pure Orin functions marked with the built-in `@Processor(A)`. They receive an
   immutable snapshot of the annotated declarations and return new declarations as typed builder values (`std:meta`).
3. **Execution** is out of process: the compiler builds the processor into a small helper executable (the same
   machinery as `orin test`) and runs it with no grants, under a deadline and memory/output limits. Purity is proven
   by the existing purity and effect analyses, not by a sandbox, so a processor *cannot* perform I/O.
4. **Output** goes into a virtual companion module `<module>.gen` per annotated source module. User code imports it
   like any module; the generated code is re-checked, ownership-verified and compiled like hand-written code.

No mutable AST plugins, no raw source strings, no native in-process plugins, no runtime reflection (alternatives below).

## 1. Definitions and uses

```ts
// web/route.or (a library)
@Annotation(method, function)
export type Route = { path: string; verb: Verb; auth: Option<string>; };
export type Verb = Get | Post | Put | Delete;

@Annotation(type, class)
export type Json = { };                       // marker: no fields

@Annotation(field)
export type JsonName = { name: string; };
```

```ts
import { Route, Get } from "web/route";
import { Json, JsonName } from "std:json";

@Json
export type User = { id: int; @JsonName("display_name") name: string; tags: string[]; };

export class Users {
  @Route("/users/:id", Get)                   // `auth` is an Option and trailing: omitted means None
  find(id: int): Result<User, string> { ... }
}
```

* **Definition.** `@Annotation(targets...)` on an exported or module-private record type. Targets are the words
  `function`, `method`, `class`, `type` (aliases, records, unions), `interface`, `field` (record and class fields),
  `const` (module constants). Parameters and statements are not targets. The record's fields are the parameters, in
  declaration order. Field types are limited to `bool`, the integer types, `float`, `string`, a payload-free union
  of tags (`Verb`), `T[]` and `Option<T>` of those. Other field types are an error at the definition (E0446).
* **Use.** `@Name` for an annotation without fields, otherwise `@Name(a1, a2, ...)` with positional arguments in field
  order; trailing `Option` fields may be omitted (None). Arguments are **constants only**: literals (with unary `-`),
  array literals of constants, tag names of the field's union, and references to module `const`s whose initialiser is
  itself a constant. No calls, no operators, no user constructors: argument evaluation runs no code. Named arguments,
  defaults other than `Option` and repeated application are not in this ADR (repeat is E0442 as today).
* **Resolution.** An annotation name resolves like a type name: declared in the module or imported. Built-in names
  (`Test`, `Deprecated`, `Inline`, `Sealed`, `Annotation`, `Processor`) and the contract clauses (`Requires`,
  `Ensures`, `Invariant`, `Decreases`, `Rule`) stay keywords of the grammar; an `@Annotation` definition cannot take
  one of these names (E0447). An unknown `@Name` stays E0408; a known name on a wrong target is E0440,
  wrong arguments E0441 (both extended from built-ins to user annotations).
* **Placement.** As today: annotations precede the declaration, any order with contract clauses; fields of records and
  classes gain annotations (they are E0408 today). The formatter prints each on its own line; a field annotation
  stays on the field's line when it fits.
* **Retention.** Compile time only. Nothing is stored in the binary; there is no reflection API. The annotation's
  record type is still an ordinary type that code may use as a value.
* **Tooling.** Uses are references in the semantic index (go to definition, rename, find references), hover shows the
  applied arguments, `orin api` prints annotation lines of exported declarations (changing them is an API change),
  OSIG gets `ANNOTATED_WITH` edges (declaration -> annotation type, with the argument values) and MCP `symbols` lists
  them. This makes metadata-only annotations (`@Description`, `@Permission`, `@Example`) useful on their own.

* **As built in S1 (2026-10-16).** The reserved names only restrict `@Annotation` definitions (E0447): an ordinary
  type, function or import called `Rule` or `Inline` stays legal, because `@Rule`, `@Inline`, ... are decided by the
  parser before name resolution and cannot be confused with a user annotation. The `__g` check is in the parser
  (`parseIdent`), so S4 builds generated AST directly and `orin expand` output that contains `__g` names is for review,
  not for re-parsing. A `@Name` on a statement stays E0408 (parse time).

* **As built in S2 (2026-10-16).** `SemanticIndex.annos` (`AnnoUse`: owner def, name, name span, resolved record, argument
  texts as written) feeds everything. A use is a reference to its `@Annotation` record (`SymbolRef` at the name, so go to
  definition, find references and rename work; the arguments that are module constants are references too). The hover text
  (`SymbolDef.detail`) of every annotated declaration, including record and class fields and constants, starts with the
  annotation lines as written, so hover on a declaration shows the annotations with their arguments and hover on the name
  shows the definition. `orin api` prints those lines for exported declarations (`@Test` and `@Inline` stay out), so adding,
  removing or changing an annotation is an API change for `--check`. OSIG is `osig/0.4` (ADR-0023: a new edge kind is a minor
  version): `ANNOTATED_WITH` edges carry the arguments as written in `via`; nodes and edges of programs without user
  annotations are unchanged, only the `schema` string and the hash differ. MCP `inspect` has an `annotations` array.
  `orin diff` does not compare `ANNOTATED_WITH` edges yet.

## 2. Processors

```ts
// std:json (stdlib/json.or), next to `Json`
import { Input, Output, MDecl } from "std:meta";

@Processor(Json)
export function jsonCodecs(input: Input): Output { ... }    // builds encodeUser / decodeUser
```

* **Declaration.** `@Processor(A)` on an exported top-level function `(input: meta.Input): meta.Output` in the module
  that declares annotation `A` (one processor per annotation; E0448 otherwise). The function and everything it calls
  must be pure in the sense of the contract checker (`check/purity.or`) and have no effects in `orin effects` (no
  grant parameter can reach it, so no file, clock, random, process or network access exists). Violations are E0448
  with the purity explanation the contract checker already prints.
* **Opt-in.** A processor runs only for modules that *import* its annotation and use it. Importing is the explicit
  dependency; nothing is scanned or discovered from the filesystem. A package may restrict processors from
  dependencies with `[annotations] processors = ["dep/module"]` in `orin.toml` (absent: every imported processor of
  the package's own modules and `std` runs; dependency processors need the list). This is the trust policy.
* **Input** (`std:meta.Input`, immutable values, deterministic order): the source module's path, and for every
  declaration annotated with `A` in that module its kind, name, export flag, type parameters, fields (name, type,
  field annotations), constructor parameters, method signatures with their annotations, union variants, doc comment,
  contract clauses as read-only text, and the applied arguments as typed constants. Types are a structured `MType`
  tree (named + arguments, array, Option, Result, function, union), and every named type that occurs is listed once
  with its own shape when it is visible from the source module. Private declarations of *other* modules never appear.
* **Output** (`std:meta.Output`): a list of declarations built with `std:meta` builders (functions, constants, records,
  unions, classes without inheritance), imports the generated code needs, and diagnostics (errors and warnings with a
  span chosen from the input, never a free position). Builders construct a typed tree (`MDecl`, `MStmt`, `MExpr`,
  `MType`) covering the ordinary statement and expression forms: literals, names, calls, method calls, fields, index,
  record/array literals, unary/binary operators, `match` on unions/Option/Result, `?`, `if`, `for of`, `while`,
  `const`/`let`, assignment, `return`. No raw text, no MIR, no LLVM.
* **Hygiene.** Names that the processor exports are public and must be declared as such (`exportDecl(d, true)`); they
  are checked for collisions with each other and with other processors' output in the same companion (E0449). Helper
  names come from `meta.fresh("tmp")`, which yields `__g<N>_tmp`; identifiers starting with `__g` are reserved for
  generated code (E0447 in user code). Local variables in generated bodies are scoped like any Orin block.

## 3. Execution model

* **Build.** For each processor in use, the compiler builds one helper executable: the processor's module, `std:meta`,
  and a generated `main` that reads the encoded `Input` from stdin, calls the processor and writes the encoded
  `Output` to stdout (same approach as the `orin test` harness, ADR-0024). Only the harness performs I/O; the
  processor function is proven pure, which is the safety argument.
* **Run.** One process per (processor, source module), started through the shell runner of `orin test` (bounded by `std:io.shellTimeout` once ADR-0045 is on
  `main`) with a deadline (default 10 s, `--processor-timeout`), `ORIN_DENY=all`, a heap limit and an output limit (default 16 MiB of
  encoded output, 10,000 generated declarations per program). Any failure (trap, timeout, limit, malformed output) is
  an error E0520 with the processor's name, the source module and the captured stderr; there is never a partially
  expanded program.
* **Determinism.** A pure function of an immutable input terminates with the same output or fails; the input encoding
  has a fixed order and no timings, paths are relative to the package root. A failure by deadline is not
  reproducible in principle, which is why it is an error and never produces output (instead of fuel accounting; a
  fuel-metered evaluator is a possible later replacement with the same interface).
* **Cache.** Helper executables and outputs are cached in the build directory under a key of compiler version, the
  processor's module closure hash, and the encoded input. `orin check` and the LSP use the cache; when no C compiler
  is available they report W0490 ("processors not run") and treat `.gen` imports as unresolved.

## 4. Generated companion modules and the pipeline

* Every source module `M` that uses at least one annotation with a processor gets a virtual module `M.gen`
  (`import { encodeUser, decodeUser } from "./models.gen"`). It contains the output of all processors run over `M`, in
  processor order (by annotation module path, then annotation name). It does not exist on disk; `orin expand <file>`
  prints every companion through the formatter, which is the review path and the golden-test format.
* `M.gen` can see `M`'s declarations, including non-exported ones (it is generated *for* `M`, like a nested part of
  the module) and may import what its `Output` asks for. It exports only what the processor exported.
* **No cycles:** a module that uses processor annotations must not import any `.gen` module, directly or
  transitively (E0521). This keeps one expansion round and a simple order.
* **Pipeline.** (1) Load all units; `.gen` specifiers are placeholders. (2) Check the sub-program of units that do not
  depend on a `.gen` module (contains every source module by E0521). (3) Build snapshots, run processors.
  (4) Convert outputs into AST units with spans pointing at the annotation that caused them (diagnostics in generated
  code say "in code generated by `jsonCodecs` for `@Json` on `User`"). (5) Check the complete program again, then
  HIR -> MIR -> verifier -> backends unchanged. Generated code gets no trust: it passes the same checker, ownership
  verifier, contract and effect analyses as user code, and its effects count for capability policies. Programs
  without processor annotations skip steps 2-4.
* Annotations inside generated code are inert (no second round). Generic instances are expanded after generation, so
  processors see declarations, never monomorphised instances.
* OSIG records `GENERATED_BY` edges (generated symbol -> processor -> annotation use, with the span), and `orin diff`
  reports generated symbols separately.

## Slices and merge gates

Each slice is one PR against `main`, merged when CI is green. Compiler slices start after the ADR-0047 layout move is
on `main`; parser and checker overlaps with ADR-0049 are coordinated with that work.

| Slice | Content | Gate |
|---|---|---|
| **S1 definitions and uses** | AST `ACustom(name, args)`; parser for user annotations on all targets incl. fields; `@Annotation` definitions; resolution, constant arguments, targets, duplicates, reserved names (E0440-E0442 extended, E0446, E0447); formatter | parse/format/check tests per error code, byte-identical output for unaffected programs, bootstrap fixed point |
| **S2 metadata in tooling** | semantic index references, hover, rename, `orin api`, OSIG `ANNOTATED_WITH`, MCP | LSP and OSIG golden tests (**done**, `tooling/protocol` (lsp, mcp), `tools/test_osig.py`, `tools/test_annotations.py`) |
| **S3 `std:meta`** | `Input`/`Output`/`MDecl`/`MStmt`/`MExpr`/`MType`, builders, `fresh`, the stable JSON encoding of both | pure std tests with `@Test`; round-trip encode/decode; parallel to S1 |
| **S4 expansion without execution** | `.gen` placeholders in the loader, sub-program check, snapshot extraction, Output -> AST conversion, hygiene and collision checks (E0449, E0521), re-check, `orin expand`; test hook that feeds a recorded `Output` | goldens from recorded outputs, negative tests (bad names, cycles, private leaks, generated type errors), both backends |
| **S5 processor execution** | `@Processor` rules and purity (E0448), harness build, run with limits (E0520), cache, `[annotations]` policy, W0490 | tests for traps, timeouts, oversized output, impure processors, cache hits |
| **S6 proof of usefulness** | `@Json`/`@JsonName` with `jsonCodecs` as an **example package** `examples/json-codec` (owner decision 2026-10-16: not in the compiler, not in `std`); a route-table example `examples/routes` (`@Route`); docs, known limitations | goldens, C/LLVM differential on generated code, compile-time numbers in docs/benchmarks.md |

**As built in S4.** The test hook is a sidecar file `<module path without .or>.gen.<AnnotationName>.json` next to the source
module, holding a recorded `std:meta` `Output` (docs/annotation-processors.md). It is read only when the program imports a
`.gen` module, or for `orin expand`; annotations without a sidecar stay plain metadata. Code of a companion module may import
only modules the program has already loaded (E0520 otherwise; the manifest rules of `orin.toml` apply, E0501). Codes:
E0449 duplicate exported name in a companion, E0521 cycle (a companion imported while its source loads, or a module that
runs a processor and depends on a companion), E0520 unusable recorded output (S5 reuses it for harness failures), E0522 an error
diagnostic reported by the processor, W0491 a processor warning. The span of generated nodes is the annotation use of the first
annotated declaration of the run; diagnostics inside generated code carry a note naming the run. Compiler code: `compiler/meta`
(snapshot, Output to AST, hygiene), `compiler/expand` (pipeline, `orin expand` text). Not done in S4: LSP, MCP, `orin test`
and OSIG do not run the expansion (a `.gen` import is E0300 there); OSIG `GENERATED_BY` edges.

**As built in S5.** `@Processor(A)` is read by the parser as the user annotation `Processor` with one argument (no parser change);
`check/userannos.or` skips that name and `compiler/expand/processors.or` does the rest: placement, signature, "same module as `A`",
one per annotation, and purity (`inferPurity` of the contract checker; the explanation is the one `E0416` prints), all E0448. The
purity analysis already counts every I/O built-in and every grant as impure, and the signature gives a processor no grant, so no
separate effects pass runs. `compiler/expand/helper.or` builds the helper by loading the processor module together with a
generated overlay file `__orin_processor_main.or` through the ordinary loader (module rules apply as for any file of that
directory), compiles it like `orin test` does (C backend only; `--cc`, `--runtime`) and runs it with `ORIN_DENY=fs,process,clock,net`
(not `all`: the harness exchanges `Input`/`Output` over stdio, and the processor has no grant to reach it), the deadline of
`std:io.shellTimeout` (`--processor-timeout`, default 10 s), the output piped through `head -c` (16 MiB) and the global limit of 10,000
generated declarations; every failure is E0520 with the stderr as a note. A heap limit is not implemented (deadline and output cap
only). The cache lives in `<package>/.orin/processors/<helper key>/` (`--processor-cache`): `helper` and `out-<input key>.json`;
the helper key hashes the format version, the generated main and path and text of the processor module's import closure (std
included); the C compiler is not in the key, so `orin check` can use a cache built by another compiler. `orin check` without a C
compiler and without a cached helper reports W0490 and leaves the companion empty; `compile` and `expand` fail with E0520. The
trust policy is `[annotations] processors = ["dep", "dep/module"]` (a dependency name, or dependency and module path below its
`src`); an unlisted dependency processor is not run and reports W0492. A recorded sidecar output (the S4 hook) wins over a processor.
New codes: E0448, W0490, W0492. Not done in S5: LSP, MCP, `orin test`, `orin graph`, `orin effects` do not expand; OSIG `GENERATED_BY`;
the helper is always built with the C backend; no memory limit.

**As built in S6 (2026-10-16).** `@Json` is not part of `std:json` or the compiler: `examples/json-codec/lib` is an ordinary package
(annotations `Json`, `JsonName`, the processor `jsonCodecs`, and a runtime support module that the generated code calls) and
`examples/json-codec/app` uses it through a path dependency with `[annotations] processors = ["json-codec"]`. The processor
needed no compiler change. Findings that shape the example: a dependency exposes only its root module `src/module.or`, so the
runtime support is re-exported from it; there are no import aliases, so `std:json`'s `Json` value type is exported as `JsonValue`
(the annotation owns the name `Json`); a processor is stateless (parameters and class instances cannot be mutated through a call),
so helper names are a function of the type (`fresh("encArrOfstring", freshBase)`); `std:json` has integers only, so `float` fields are
a processor diagnostic; a companion cannot import another companion (E0520, one round of expansion), so a `@Json` record nested in
another record must be declared in the same module (cross-module nesting is a diagnostic that says so). `examples/routes` generates
a route table and a matcher from `@Route` on methods; handlers are named, not called (a processor cannot form a method value).
Tests: `tools/test_processors.py` (goldens of `orin expand`, C and LLVM output identical, diagnostics of `tests/processors/json_bad`).

S1 and S3 can run in parallel (parser/checker vs. std only). S2 follows S1; S4 needs S1 and S3; S5 follows S4; S6
follows S5. Every slice keeps contracts, built-ins and their codes unchanged.

## Alternatives

* **Mutable AST plugins:** rejected; contracts, provenance and verification become hard to reason about.
* **Raw generated source strings:** rejected as the API; poor hygiene and unstable diagnostics. `orin expand` prints
  source for review only.
* **Native plugins inside the compiler process:** rejected; no trust boundary.
* **A restricted compile-time VM with fuel** (first draft of this ADR): deferred. It would need a second evaluator
  for the whole language; a proven-pure function in a subprocess with a deadline gives the same safety (no I/O) with
  the existing backends. The `Input`/`Output` interface stays the same if a VM replaces the subprocess later.
* **In-place generation** (methods added to the annotated class, like Rust `derive`): not in this ADR; it needs
  member injection and creates the cycle that the companion module avoids. Possible follow-up with its own ADR.
* **Runtime reflection or proxies:** rejected (spec 05).

## Not in this ADR

Named and default arguments beyond trailing `Option`; repeatable annotations; annotations on parameters and
statements; processors that aggregate over the whole program (a single route table across modules: today each
module's companion exports its part and user code combines them); in-place member generation; a fuel-metered
evaluator; processors from a package registry (no registry exists, ADR-0016).

## Amendment to ADR-0016

The "Annotations" row of ADR-0016 changes from "user-defined annotation processors are post-1.0" to "user-defined
annotations and pure processors per ADR-0046 are in 1.0 scope (owner decision 2026-10-16)". The language freeze
covers them once S1-S5 are on `main`.
