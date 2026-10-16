# Bootstrap plan

The build starts from a committed **seed**, the generated C of a self-hosted compiler
(`seed/orin-seed.c.gz`, described by `seed/SEED_INFO`). Only a C compiler, python3, gzip and
sha256sum/shasum are required. The seed is the **single root** of the build (ADR-0014, ADR-0015); the
Rust Stage 0 is retired (see "Retired Stage 0" below).

| Stage | Built by | Source | Output |
|---|---|---|---|
| seed | `cc` | `seed/orin-seed.c.gz` (sha256-verified) | `orin0` |
| 1 | `orin0` | `compiler/` | `orin1` |
| 2 | `orin1` | `compiler/` | `orin2` (+ `stage2.c`) |
| 3 | `orin2` | `compiler/` | `stage3.c` — must be byte-identical to `stage2.c` |

```bash
./tools/bootstrap.sh                 # seed -> orin0 -> orin1 -> orin2 -> stage3, compare, conformance
tools/conformance.sh --orinc build/bootstrap/orin2   # the Orin runner; tools/run_tests.py is the Python oracle
sh tools/llvm_fixpoint.sh [--deep]   # LLVM fixed point (needs clang), see below
```

**LLVM fixed point (ADR-0038 section 8, gate 2).** `tools/llvm_fixpoint.sh` compiles `compiler/main.or` with `orin2
--backend=llvm`, links the `.ll` with clang to `orin2-llvm`, and lets that compiler compile `compiler/main.or` again, to C
and to LLVM IR. The C must equal `stage2.c` and the `.ll` must equal the first one, byte for byte; `--deep` repeats this
with a third compiler built from the second `.ll`. Output goes to `build/llvm-fixpoint/`. It takes about 2 minutes (3.5 with
`--deep`) on a loaded 4-CPU machine and runs in the CI `llvm` job. The release default stays the C backend.

`compiler/` is no longer restricted to Orin-B (the subset Stage 0 understood); it may use any language
feature the current seed can compile. A feature the seed cannot compile first needs a seed update
(below).

## Seed and trust chain

`SEED_INFO` records the source commit, the sha256 of the uncompressed C, how the seed was produced and
the date. `bootstrap.sh` decompresses the seed and aborts if the sha256 does not match.

Update a seed only when `compiler/` starts using a feature the current seed cannot compile:
`tools/update_seed.sh` (bootstraps from the current seed, then writes `orin-seed.c.gz` with `gzip -9n`
and `SEED_INFO`). Commit the result in a dedicated PR that shows the full bootstrap from the *old* seed
to the new compiler. The seed equals `stage2.c` (also shipped as `share/orin/orin-seed.c` in releases),
so a seed that is current with `compiler/` is a fixed point: bootstrapping from it yields a `stage2.c`
with the same sha256 as the seed.

## Retired Stage 0 (Rust)

The Rust Stage 0 (`orinb`, compiled Orin-B only) was removed from `main` in the first post-freeze cleanup
PR, because the compiler rewrite (ADR-0015) uses language beyond Orin-B. It is archived, complete and
buildable, on the git branch **`archive/stage0-final`** (commit `ec1ba3e`, the last commit of `main` that
contained it: the `bootstrap/` crate, `tools/diff_parsers.py`, `tools/stage0/`, and
`tools/bootstrap.sh --from-stage0`). Its documented contract is `docs/bootstrap-subset.md`.

**Diverse double root evidence.** Until `ec1ba3e` CI required that the seed root and the Rust root
produce a byte-identical `stage2.c`. For the seed refreshed from `ec1ba3e` (`seed/SEED_INFO`,
sha256 `a7ec8b3b...40c6`, 5590974 bytes) this was checked once more before Stage 0 was removed: both
roots gave the same `stage2.c`. To reproduce it:

```bash
git worktree add ../orin-stage0 archive/stage0-final     # or: git checkout archive/stage0-final
cd ../orin-stage0
./tools/bootstrap.sh --from-stage0                       # needs cargo; Rust root -> orin1 -> orin2 -> stage3
sha256sum build/bootstrap/stage2.c                       # must equal the sha256 in seed/SEED_INFO of main
```

What is established: the seed whose source commit is `ec1ba3e` is exactly what a toolchain with no
Orin-generated code in its history (Rust Stage 0 built by rustc, then `cc`) produces from the sources
at `ec1ba3e`. A self-reproducing defect carried only in the previous seed lineage would have shown up as
a difference.

What is **not** established: from now on the seed is the single root. Later seeds are produced by the
previous seed (`produced-by` in `SEED_INFO`) and checked only by `stage2.c == stage3.c`, which cannot
detect a defect that the bootstrapping compiler reproduces in every generation, and no second
independent root exists for the rewritten compiler (Stage 0 cannot compile it). The evidence for a later
seed is therefore: a clean seed at `ec1ba3e` (above), the reviewed source diff since, and the fixed
point. That is a chain argument, not a repeated diverse-root check. The only remaining diversity is the
choice of C compiler (and the C-backend vs LLVM-backend equality); a new independent root would need a
second implementation of the then-current language, which is not planned.

The self-hosted compiler also embeds the std prelude (`library/core/`, spec 19 R1; docs/architecture.md
"Preludes"). `tools/bootstrap.sh` first checks that `compiler/loader/embedded_std.or` is up to date
(`tools/embed_prelude.py --check`). Every stage compiles `compiler/` with the prelude (library calls inside the compiler become Orin
code); `--c-builtins` keeps the C runtime implementations, and `tools/differential.sh --mode builtins`
compares the two.

All stages share the CLI `<compiler> compile <entry.or> -o <out.c>` and the C runtime.
Generated C must not contain timestamps, absolute paths or hash-order-dependent output.
Stage equality is a consistency check, not a correctness proof (spec 09).

## Stage 1 layout (`compiler/`)

Each directory is a module (`module.or` = public API). Contracts written by the lead:
`diag/diag.or`, `syntax/ast.or`, `hir/hir.or` (originally mirrors of the Rust Stage 0 `span/diag`, `ast`, `hir`; see the archive branch).
Components began as ports of the Stage 0 Rust components with the same behaviour and diagnostics.

## Language growth in the self-hosted compiler

Until the Stage 0 retirement `compiler/` had to stay within Orin-B; that restriction is lifted (see
above), though `compiler/` has not been rewritten yet. Features beyond Orin-B get an ADR and tests under
`tests/next/` (run with `tools/conformance.sh --orinc build/bootstrap/orin2 --suite next`;
`--suite all` runs both suites).

* Generics (ADR-0007): `check/types.or` (type resolution, instantiation, unification),
  `check/body.or` (call/record inference), `check/checker.or` (abstract checks, instance loop).
  Checker functions thread the growing environment through `FnCtx.env`.
* Classes (ADR-0009): `syntax/` (`IClass`, `ENew`, `EThis`; `class`/`new`/`this` stay reserved words,
  `private`/`public`/`static`/`extends`/`constructor` are contextual), `check/classes.or`
  (desugaring of each class into a record + constructor function + method functions `C.m(this$, ..)`,
  class tables, lookups), `check/classfix.or` (inferred-mutability fixpoint by probing method bodies,
  `$ret` records), `check/body.or` (`new`, method/static calls, `p = C.m(p, ..)` lowering through
  hoisted statements `FnCtx.pre`, private access E0405, `this` errors E0300, const receiver E0401),
  `check/index.or` (class/field/method defs and refs; method detail `mut method m(..)` when inferred
  mutating), `fmt/printer.or`. HIR and backends are unchanged.

* Closures (ADR-0011): `syntax/` (`EArrow`, `TFn`), `check/fnctx.or` (captures), `check/body.or` (closure
  conversion, function values, array methods), `check/types.or` (`TyFn`), HIR `TyFn` / `XClosure` /
  `XCallIndirect`, MIR `IClosure` / `ICallIndirect` (docs/mir.md v1.3), `lower`, `opt` (closure targets keep
  borrowed parameters), `verify`, `cemit`, `llvm`. The array API prelude is `library/collections/array.or`
  (prelude root `$array`, embedded via `tools/embed_prelude.py`). `compiler/` itself still uses no closures.

* Fixed-width integers and template literals (ADR-0022): `syntax/lexer.or` (`KBigInt`, `KTpl*`, brace-depth stack), `ast.or` (`EBigInt`, `ETemplate`), `hir.or` (`TyIntK`, the integer kind helpers, `BInt*` built-ins), `check/ints.or` (type names, literal fitting, conversions, `wrapping*` etc.), `check/body.or` (`checkIntLit`, `checkTemplate`, `intMethodCall`), `lower` (`rangeCheck` after narrow arithmetic), `cemit` / `llvm` (the seven built-ins), runtime `orin_int_op` / `orin_int_chk` / `orin_parse_int_k`, `fmt/printer.or` (verbatim templates), `syntax/trivia.or` (comment scan skips templates). The compiler source itself uses none of it.
* Floats and `Map<K, V>` (ADR-0018): `syntax/lexer.or` (`KFloat`), `EFloat`, HIR `TyFloat`/`TyF32`/`XFloat` and the `BFloat*` builtins, `check/` (literal typing, `methodSig`, `Map` hooks in `types.or`/`body.or`), MIR `MFloat`/`OFloat`, `lower` (f32 rounding), `verify`, `cemit`, `llvm`, runtime `orin_float_to_string` etc.; Map and std:math are Orin prelude code (`library/collections/map.or`, `library/collections/math.or`). Programs using floats link with `-lm`.

## Writing efficient Orin-B (important for Stage 1 authors)

Orin-B values are immutable-by-default RC'd objects; `let` mutation is copy-on-write and is
in-place only while the object is uniquely referenced. Parameters are borrowed. Hence:

- Grow arrays only in `let` locals of the function that owns them (`xs.push(v)` is amortised
  O(1)). Never copy a large array into a `let` just to push to it (`let ys = param; ys.push(..)`
  copies the whole array once).
- Thread positions/indices, not big state: e.g. the parser passes the immutable token array
  plus a `pos: usize` and returns small result records `{ node, pos }`.
- Return new values bottom-up (trees, strings, line arrays) and let callers append them.
- Build large output with `string[]` + `join("")`, not repeated `s += ...` on long strings.
- No hash maps in Orin-B: use arrays + linear search for small tables; for large tables keep
  them sorted or bucketed by a simple string hash computed with `charCodeAt`.
