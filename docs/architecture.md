# Orin Compiler Architecture

Status: living document. Owner: lead architect. Normative source of language requirements is
`spec/`; this file records how the implementation realises them.

## Repository layout

| Path | Contents |
|---|---|
| `spec/` | Language/product specification (authoritative). |
| `docs/bootstrap-subset.md` | Historical: the frozen Orin-B subset of the retired Stage 0 (diagnostics table still valid). |
| `docs/decisions/` | ADRs (interpretations of OPEN points, deviations). |
| `seed/` | The committed **seed** (generated C of the self-hosted compiler, `orin-seed.c.gz` + `SEED_INFO`), the single bootstrap root. The Rust Stage 0 is retired to branch `archive/stage0-final`. |
| `platform/` | **L0 platform layer** (spec 19 R2): `orin_platform.{h,c}`, the closed list of OS/libc primitives with ACSL-style contracts; `platform/tests/` (contract tests, CBMC harnesses). |
| `runtime/` | C runtime `orin_runtime.{h,c}` (object model, strings, arrays, traps) shared by all stages' generated code; reaches the OS only through `platform/`. |
| `compiler/` | **Stage 1+** compiler written in Orin (`compiler/main.or`). |
| `stdlib/` | **Std modules in Orin** (`std:fs`, `std:path`, `std:json`, `std:time`, `std:graph`): embedded library root, see docs/std.md. |
| `std/` | **Std prelude** in Orin (spec 19 layer L2): library logic compiled with every program (see "Preludes"). |
| `tests/run/` | Conformance programs: `x.or` + expected stdout `x.out`. |
| `tests/errors/` | Must-fail programs; first line `// error: E0xxx`. |
| `tests/next/` | Same formats (`run/`, `errors/`) for language beyond Orin-B; self-hosted compiler only (`--suite next`). |
| `tools/` | Test runner and bootstrap scripts. |

## Pipeline

```
file.or ──lexer/parser──▶ AST ──loader (imports, module rules, DAG)──▶ units (topo-sorted)
      ──checker (resolve + type)──▶ typed HIR ──lower──▶ MIR ──verify──▶ GNU C / LLVM IR ──cc + runtime──▶ native exe
```

The former direct HIR -> C backend (`compiler/codegen/`, `--legacy-codegen`) was removed in the first
post-freeze cleanup; HIR is lowered to MIR and emitted by `compiler/cemit` or `compiler/llvm` only.

(Historical: the Stage 0 contracts were the Rust modules `span.rs`, `diag.rs`, `ast.rs`, `hir.rs`,
`loader.rs`; they now live only on the archive branch.)
Planned later passes (spec 09): annotation expansion and class lowering between AST and HIR;
MIR/OIM memory IR + independent verifier between HIR and codegen.

## Runtime object model (v1, ADR-0002)

- **Scalars** (`int`→`int64_t`, `usize`→`uint64_t`, `bool`→`int64_t` 0/1 or C `bool`) are unboxed.
- **Every other value** (string, array, record, union, Option, Result) is a pointer to a
  reference-counted heap object with a common header. Values are immutable from the program's
  point of view; mutation of a `let` place is copy-on-write: the runtime mutates in place only
  when the object's count is 1, otherwise it copies first. This realises the value semantics of
  spec 03/06 (`const b = a; a.x = 1` leaves `b` unchanged). Because values are created
  bottom-up and never mutated while shared, owning cycles cannot form.
- Object kinds:
  - **String**: immutable bytes + length. Literals are immortal static objects.
  - **Array**: length, capacity, `elem_is_ref` flag, buffer of 64-bit slots.
  - **Struct** (records, union variants, Option, Result): `tag`, slot count, per-slot
    "is reference" bitmask (≤ 64 slots), 64-bit slots. Records use tag 0. Nullary variants
    may be immortal shared singletons.
- Releasing an object to count 0 releases its reference slots, then frees it. Immortal
  objects (negative count) are never freed or counted.
- **Ownership convention in generated code:** function parameters are *borrowed*;
  return values are *owned* (+1); locals own their value; storing a borrowed value
  (into a local, field, array, return) retains it; owned temporaries that are only borrowed
  are released after use. Locals are released at scope exit (including `break`, `continue`,
  `return`). Early exits from inside an expression (`?`, diverging match arms) may leak
  already-evaluated temporaries — a leak, never a use-after-free. Counts must never be too low;
  too high only costs memory and extra copies.
- Checked arithmetic uses `__builtin_*_overflow`; traps call `orin_trap(msg)` → stderr
  `trap: msg`, exit 101.

## Preludes (std in Orin, spec 19 R1)

A **prelude** is a directory of ordinary Orin sources that the self-hosted compiler loads implicitly
into every program, so library logic can be written in Orin instead of C. Mechanism (all deterministic,
so `stage2.c == stage3.c` still holds):

- **Source and embedding.** `std/` (repo root) holds the std prelude: `module.or` (entry, lists the
  rules) + `strings.or`, `numbers.or`. The compiler is one native binary and cannot find files next to
  itself, so `tools/embed_prelude.py` turns each prelude directory into a generated Orin file
  (`compiler/loader/embedded_std.or`, a function returning `SourceFile[]`). Run the script after
  editing `std/`; `tools/bootstrap.sh` fails on a stale file (`--check`).
- **Prelude roots (the general mechanism).** `compiler/loader/prelude.or` has `preludeRoots()`, a list
  of `PreludeRoot { entry, files }`. `loadWithRoots` (loader.or) serves every root's files from memory under
  virtual paths `$<name>/...` and adds an empty import of each root's `entry` to the program's entry
  file, so the prelude units come first in the topologically sorted unit list. Unit names are the
  virtual path without `.or` (`$std/strings`), so qualified function names are stable
  (`$std/strings.strSplit`). **The leading `$` marks prelude code** everywhere downstream. To add another
  prelude (e.g. closures + the array API): put the sources in their own directory, add a row to
  `PRELUDES` in `tools/embed_prelude.py`, add one `PreludeRoot` in `preludeRoots()`; nothing else in the
  loader changes. (Separate directory, separate embedded file, one line each in two shared lists: the two
  preludes merge without touching each other's files.)
- **Lowering.** The checker is untouched: `s.split(x)`, `parseInt(s)`, `n.toString()` ... still check to
  `XBuiltin` with the same signatures. `compiler/lower/prelude.or` maps the moved built-ins (table
  `preludeSlot` + `preludeNames`) to the prelude function of that name; `exprBuiltin` (lower/body.or)
  then lowers them like an `XCall`. If the program has no such function (`--c-builtins`) the built-in is
  emitted as before, as a runtime C call.
- **No bloat.** `compiler/opt/prune.or` (run after the optimiser and the verifier, just before C emission)
  drops prelude functions (names starting with `$`) that are not reachable from `main` or from the
  program's own functions, renumbering calls. `orin mir` / `orin verify` do not prune, so
  `tools/verify_all.py` verifies the whole prelude. A new MIR instruction that names a function must be
  added to `callees`/`renumber` there.
- **Flags.** `--c-builtins` keeps the C runtime path (differential testing:
  `python3 tools/diff_backends.py --mode builtins`); `orin check` loads no
  prelude.
- **Rules for prelude code** (also in `std/module.or`): only the primitives the C runtime keeps
  (`length`, `charCodeAt`, `charAt`, `substring`, `String.fromCharCode`, `+`, array `push`/index/`length`,
  console, `process.exit`); never call a built-in that is itself implemented in the prelude (the lowering
  would make it a recursive call); keep within what the self-hosted compiler accepts.

## Platform layer (spec 19 R2)

Everything the runtime needs from the OS or libc goes through `platform/orin_platform.h`: memory
(`alloc`/`realloc`/`free`, `mem_copy/move/set/cmp/find`), decimal formatting, process (`init`, `arg_count/arg`,
`getenv`, `at_exit`, `exit`, `abort`, `shell`), byte I/O (`write`, `write_line`, `flush`, `stdin_read`,
`stdin_getc`) and whole-file operations (`file_read/write/exists`, `error_message`). `runtime/*.{c,h}` include only
freestanding headers (`stddef.h`, `stdint.h`) plus the platform header; `tools/check_platform_boundary.sh`
(run in CI) fails on any direct libc call or libc include in `runtime/`. The runtime includes the header as
`../platform/orin_platform.h`, so `platform/` must be a sibling directory of `runtime/` in a checkout and in
a package (`lib/orin/runtime`, `lib/orin/platform`); every link line is
`cc -I runtime out.c runtime/orin_runtime.c platform/orin_platform.c`. The memory primitives are `static inline`
in the header (no cost on hot paths); everything else is out of line. The platform layer owns the process-wide
stdout buffer and the argv copy; the runtime keeps no libc state. Contracts, status labels and verification:
docs/formal.md "L0 platform layer".

## Safety status (honest labelling, spec 07)

| Property | Status |
|---|---|
| Bounds-checked indexing, checked arithmetic | Implemented in runtime/codegen; tested only |
| Library string/number functions (R1) | Safe Orin in `std/` (checked by the compiler, verified by the MIR verifier, `tools/verify_all.py`); functional behaviour tested only, differentially against the C implementations |
| RC never under-counts (no UAF/double free) | Generated code: tested + ASan/UBSan on all suites and on the compiler self-compiling. Abstract machine: **proven** in Lean (`formal/`, theorem `run_safe`; rc ≥ owners invariant) — see docs/formal.md |
| Value semantics / COW | Abstract machine: **proven** for `makeUnique; store` (`makeUnique_store_cow`); generated code: tested |
| MIR ownership discipline | Independent verifier implemented (`compiler/verify`, docs/mir.md); lowering to MIR in progress; verifier itself not mechanically verified |
| Link verifier ⇄ Lean model | **Proven for the structured MIR core** (`check_sound`: Lean checker transcribing docs/mir.md accepts ⇒ no use-after-free/double free/shared store), given a caller contract. Not covered: calls/builtins, loops, switch, arrays/strings; the Orin verifier source is not itself verified against the Lean checker (manual transcription). See docs/formal.md |
| Source type safety (progress/preservation) | Not started |
| L0 platform layer (`platform/`) | Contracts written (ACSL-style); memory/string/format primitives bounded-verified with CBMC; I/O, process and file primitives tested only (docs/formal.md) |
| Native artifact | TCB: runtime, C compiler, allocator, emitter — unverified |
