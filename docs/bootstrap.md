# Bootstrap plan

Default build (ADR-0014) starts from a committed **seed**, the generated C of a self-hosted compiler
(`bootstrap/seed/orin-seed.c.gz`, described by `bootstrap/seed/SEED_INFO`). Only a C compiler, python3,
gzip and sha256sum/shasum are required; Rust/cargo is **not** needed.

| Stage | Built by | Source | Output |
|---|---|---|---|
| seed | `cc` | `bootstrap/seed/orin-seed.c.gz` (sha256-verified) | `orin0` |
| 1 | `orin0` | `compiler/` | `orin1` |
| 2 | `orin1` | `compiler/` | `orin2` (+ `stage2.c`) |
| 3 | `orin2` | `compiler/` | `stage3.c` — must be byte-identical to `stage2.c` |

`tools/bootstrap.sh --from-stage0` replaces the seed row by the Rust Stage 0 (`cargo build` in
`bootstrap/` → `orinb`, which compiles `compiler/` — with `std:io` stubbed, see
`tools/stage0/lsp_stdio.or` — to give `orin1`). This path needs `cargo`; it is also the only place
(besides the Rust unit tests, `cargo test`) where Rust is used. While `compiler/` is Orin-B both roots
must yield an identical `stage2.c`; CI checks this (diverse roots). `build/bootstrap/orin2` is the
output in both modes.

```bash
./tools/bootstrap.sh                 # seed -> orin0 -> orin1 -> orin2 -> stage3, compare, conformance
./tools/bootstrap.sh --from-stage0   # Rust Stage 0 -> orin1 -> ...
python3 tools/run_tests.py --orinc build/bootstrap/orin2
```

## Seed and trust chain

`SEED_INFO` records the source commit, the sha256 of the uncompressed C, how the seed was produced and
the date. `bootstrap.sh` decompresses the seed and aborts if the sha256 does not match.

Update a seed only when `compiler/` starts using a feature the current seed cannot compile:
`tools/update_seed.sh` (bootstraps from the current seed, then writes `orin-seed.c.gz` with `gzip -9n`
and `SEED_INFO`; `--from-stage0` re-roots at Stage 0). Commit the result in a dedicated PR that shows the
full bootstrap from the *old* seed to the new compiler. The seed equals `stage2.c` (also shipped as
`share/orin/orin-seed.c` in releases).

Trust chain: Rust Stage 0 → seed₁ (produced via `--from-stage0`) → seed₂ → …. Anyone can re-verify a
seed by re-running the chain from the tagged source; the C-backend/LLVM-backend equality and the
Stage 0 vs seed `stage2.c` equality in CI serve as diverse double-compilation (spec 09).

The self-hosted compiler also embeds the std prelude (`std/`, spec 19 R1; docs/architecture.md
"Preludes"). `tools/bootstrap.sh` first checks that `compiler/loader/embedded_std.or` is up to date
(`tools/embed_prelude.py --check`). The stage-1 compiler (Stage 0 or seed-built orin0) builds stage 1 with the C implementations of the library
built-ins (Stage 0 never sees `std/`); stage 2 and 3 are compiled *with* the prelude (library calls inside the
compiler become Orin code), and `stage2.c == stage3.c` additionally shows that the C-builtin and the
prelude implementations agree on the compiler's own workload.

All stages share the CLI `<compiler> compile <entry.or> -o <out.c>` and the C runtime.
Generated C must not contain timestamps, absolute paths or hash-order-dependent output.
Stage equality is a consistency check, not a correctness proof (spec 09).

## Stage 1 layout (`compiler/`)

Each directory is a module (`module.or` = public API). Contracts written by the lead:
`diag/diag.or`, `syntax/ast.or`, `hir/hir.or` (mirrors of the Rust `span/diag`, `ast`, `hir`).
Components are ports of the Stage 0 Rust components with the same behaviour and diagnostics.

## Language growth in the self-hosted compiler

`compiler/` itself must stay within Orin-B (Stage 0 compiles it), but the language it *accepts*
grows. Features beyond Orin-B get an ADR and tests under `tests/next/` (run with
`python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite next`; `--suite all` runs both
suites; Stage 0 is not expected to pass `next`). `tools/diff_parsers.py` skips `tests/next/`.

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
  mutating), `fmt/printer.or`. HIR and backends are unchanged. `tools/diff_parsers.py` skips three
  parse_edge cases that pin Stage 0's rejection of `class`/`new`/`this`.

* Closures (ADR-0011): `syntax/` (`EArrow`, `TFn`), `check/fnctx.or` (captures), `check/body.or` (closure
  conversion, function values, array methods), `check/types.or` (`TyFn`), HIR `TyFn` / `XClosure` /
  `XCallIndirect`, MIR `IClosure` / `ICallIndirect` (docs/mir.md v1.3), `lower`, `opt` (closure targets keep
  borrowed parameters), `verify`, `cemit`, `llvm`. The array API prelude is `array/array.or`
  (prelude root `$array`, embedded via `tools/embed_prelude.py`). `compiler/` itself still uses no closures (Orin-B).

* Floats and `Map<K, V>` (ADR-0015): `syntax/lexer.or` (`KFloat`), `EFloat`, HIR `TyFloat`/`TyF32`/`XFloat` and the `BFloat*` builtins, `check/` (literal typing, `methodSig`, `Map` hooks in `types.or`/`body.or`), MIR `MFloat`/`OFloat`, `lower` (f32 rounding), `verify`, `cemit`, `llvm`, runtime `orin_float_to_string` etc.; Map and std:math are Orin prelude code (`array/map.or`, `array/math.or`). Programs using floats link with `-lm`.

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
