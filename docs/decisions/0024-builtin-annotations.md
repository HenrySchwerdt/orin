# ADR-0024: Built-in annotations `@Test`, `@Deprecated`, `@Inline` and the `orin test` runner

Status: accepted (2026-10-13). Implements the "Annotations" row of ADR-0016 (spec 05, compiler
built-ins only). Related: ADR-0012 (contract clauses are not annotations), ADR-0008 (shared
semantic engine), ADR-0016 (two-stage freeze: this is part of the language freeze).

## Decision

### 1. A closed set of compiler built-ins

`@Test`, `@Deprecated("message")` and `@Inline` are **compiler-defined constructs with dedicated
grammar and AST nodes** (`syntax.Annotation`, `AnnotationKind = ATest | ADeprecated | AInline`),
exactly like the contract clauses of ADR-0012. They are *not* an annotation mechanism: a program
cannot define, import, shadow, generate or process annotations; user-defined annotation processors
and code generation stay post-1.0 (ADR-0016). Any other `@Name` remains **E0408** (the message now
lists the built-ins and the contract clauses). Contract clauses (`@Requires`, ...) are unchanged and
keep their own productions.

Syntax (one canonical form, spec 01): `@Test`, `@Inline` (no argument list, `@Test()` is E0441) and
`@Deprecated("message")` (exactly one string literal). Annotations and contract clauses precede the
declaration, may be written in any order, and are kept apart in the AST (`annotations` next to
`contracts`). The formatter prints each on its own line above the declaration: annotations first (in
the order written), then the contract clauses.

| Annotation | Allowed on | Errors |
|---|---|---|
| `@Test` | top-level functions | E0440 elsewhere; E0443 if generic, with parameters or not returning `void`; E0445 if the function is called or used as a value |
| `@Deprecated("m")` | functions, methods, classes, type declarations (alias, record, union), interfaces, interface methods | E0440 elsewhere (constants, fields, constructors, imports, statements) |
| `@Inline` | functions, methods | E0440 elsewhere; E0444 if the function is in a call cycle |

Every annotation at most once per declaration (E0442); wrong arguments E0441. All of these are
parser-level (E0440-E0442) or checker-level (E0443-E0445) *errors*, never silently ignored.

### 2. `@Test` and `orin test`

* **Shape.** A test is `@Test function name(): void`. It fails by **trapping**: a failed assertion, a
  bounds error, `unwrap` of `None`, a **violated contract** (`orin test` builds with runtime contract
  checking, ADR-0012, unless `--no-contracts` is given), a non-zero `exit`, a crash or a timeout.
  `Result`-returning tests are *not* part of 1.0: a failure value would have to be inspected and
  printed by the harness, which needs interface/trait-like display machinery the language does not
  have; `assert*` plus `?`-free test code covers the use cases. (Post-1.0 can add them without breaking
  anything, since E0443 currently rejects non-`void` tests.)
* **Erasure.** In `compile`, `mir` and `verify` the `@Test` functions are removed from the AST *after*
  a full type check of the real program (so tests cannot rot) and *before* the program that is lowered
  is checked again. Nothing a test uses (generic instances, closures, string literals, records) reaches
  the output, so the generated C and LLVM IR are byte-identical to the program with the test functions
  deleted (`tools/test_annotation_erasure.py`, same idea as the contract erasure test). `orin check`
  checks everything and erases nothing. Cost: programs that contain tests are checked twice by
  `compile`.
* **Discovery.** `orin test <file.or | package-dir>` loads the program like `check` does and discovers
  the `@Test` functions of *all loaded user modules* (units in loader order, dependencies first, source
  order inside a unit). Test ids are `<module>.<function>` (module = path relative to the entry
  directory, no extension; e.g. `mathx/add.testAdd`). A test file does not need a `main`; if the entry
  module has one it is not run. Tests live next to the code (private functions of the module are
  testable: the harness imports the tests, not the code under test) or in separate files that import
  the code; a module that nothing imports is not loaded and its tests are not found.
* **One executable, one process per test.** The runner builds ONE executable: each test is renamed to a
  unique exported `__orin_test_<N>`, the entry module imports them, its own `main` is replaced by a
  dispatcher that runs the test whose index is `argv[1]`, and a small harness module owns the argument
  handling (so the entry's own imports cannot collide with it). The runner then starts the executable
  **once per selected test** through the shell (`./tests 3 > t3.out 2> t3.err`), under `timeout(1)`
  when available (`--timeout`, default 10 s) and records the exit status. *Why re-exec instead of
  running all tests in one process:* a trap calls `exit(101)`; the language has no `fork`, no
  exceptions and no unwinding, and an in-process runner would stop at the first failure and share
  heap/global state between tests. Re-executing needs only the shell support the compiler already has
  (`std:io.shell`, used by `orin mcp` and `orin verify --contracts`), keeps every test hermetic, makes a
  hang or crash of one test harmless to the others, and costs one process start (milliseconds) per
  test. The alternative (a fork per test inside the harness) would need a new runtime primitive and is
  not portable to the L0 platform layer.
* **Reporting.** Text: `PASS id` / `FAIL id (reason) file:line:col` followed by the captured stderr and
  stdout of failing tests, and a summary line. `--format=json` prints one object with a fixed key order
  and no timings (deterministic, see docs/testing.md); `--filter S` selects tests whose id contains `S`.
  Exit status 0 when every selected test passed (or none exist), 1 on a failed test, a compile error or
  an internal failure, 2 on usage errors. Diagnostics (errors, E0301...) are reported like in `check`.
* **Assertions: `std:test`** (an Orin module in `stdlib/test.or`, imported explicitly):
  `assert(cond: bool, msg: string)`, `assertEq` (int), `assertEqUsize`, `assertEqString`,
  `assertEqBool`, `assertNear(actual, expected, tolerance, msg)` and `fail(msg)`. A failure writes
  `trap: <message>` to stderr and exits 101, the exact shape of every other trap, so the runner needs no
  special case. There is one `assertEq*` per type because Orin has no generic equality and no generic
  `toString`; this is deliberate library surface, not syntax, and can be extended without an ADR.
* **MCP.** `orin mcp`'s existing `test` tool gets `unit: true` (and `filter`): it calls the same runner
  (`compiler/testing/runner.or`) and returns the JSON report; `build` erases `@Test` functions. Both stay
  behind `--allow-exec`; the runner refuses programs that read files outside the authorized root before
  anything is executed.
* **Where it finds the C runtime.** `orin test` needs `cc` and the runtime sources like `orin build`:
  the packaged launcher (`dist/orin`) passes `--runtime <lib/orin/runtime> --cc "$CC"`; from a checkout
  the defaults (`./runtime`, `cc`) work; `--cc` accepts flags (`--cc "cc -fsanitize=address,undefined"`).

### 3. `@Deprecated` is a warning

Using a deprecated symbol is valid, so it is a **warning** (`W0440`), not an error, and never changes
the exit status. Warnings are represented as ordinary `Diagnostic`s whose code starts with `W`
(`diag.isWarning`): `render` prints `warning[W0440]`, the JSON diagnostic has `"severity":"warning"`,
LSP uses severity 2 and the `Deprecated` diagnostic tag (2) so editors strike the use through, hover
shows the annotation as part of the declaration. The warning is derived from the semantic index
(ADR-0008, `SymbolDef.deprecated`): every reference to a deprecated definition is reported *except*
inside the deprecated declaration itself, inside another deprecated declaration, and in an import list
(the uses that follow are reported). The index is only built for programs that contain a `@Deprecated`
(checked on the AST first), so other programs pay nothing. `Analysis.warnings` is separate from
`Analysis.diags`, so tools that count or guard on errors (rename, MCP `check` error counts) are
unaffected; MCP `check` does not list warnings in 1.0 core.

The public API snapshot (`orin api`) prints the annotation lines of an exported declaration, so adding
or removing `@Deprecated` is reported by `orin api --check` like any signature change. `@Test` and
`@Inline` are not part of the API (no caller can observe them) and are left out of the snapshot.

### 4. `@Inline` is a backend hint

`@Inline` marks a function or method; the checker records the names (`hir.Program.inlineFns`,
`mir.MProgram.inlineFns`, MIR v1.7) and the backends use them: the C backend emits `static inline`
(a hint the C compiler may ignore; not `always_inline`, which GCC turns into an error for the
constructs it cannot inline), the LLVM backend `alwaysinline`. **Semantics are unchanged**: the
differential tests (`diff_backends.py`, all modes) and the conformance suites pass identically with and
without it. Generic functions: every instance is marked. A function used as a value (`f(square, 3)`)
is an ordinary function value. **Recursion is an error (E0444):** an `@Inline` function that is part of
a call cycle (directly, through other functions or through closure creation) is rejected, because the
hint cannot be honoured and is almost certainly a mistake; calls through function values and interface
methods are not followed.

## Consequences

* The AST gains an `annotations` field on functions, methods, classes, types, interfaces and interface
  methods; spans of annotated declarations start at the first annotation or clause.
* New codes: E0440-E0445 (docs/bootstrap-subset.md), W0440. Stage 0 (Rust) rejects `@` and is
  unaffected; `tools/diff_parsers.py` skips the new formatter golden, everything under `tests/next` is
  already skipped.
* `std:test` is a new std module; it is loaded on demand like `std:path`.
* Not in 1.0 core: `Result`-returning tests, test fixtures/`@Before`, parameterised tests, parallel test
  execution, coverage, benchmarks (`@Bench`), a `--list` mode, per-test timeouts other than the global
  `--timeout`, annotations on constants/fields/parameters, user-defined annotations.
