# Bootstrap plan

| Stage | Built by | Source | Output |
|---|---|---|---|
| 0 | `cargo` | `bootstrap/` (Rust) | `orinb` |
| 1 | `orinb` | `compiler/` (Orin-B) | `orin1` |
| 2 | `orin1` | `compiler/` | `orin2` (+ `stage2.c`) |
| 3 | `orin2` | `compiler/` | `stage3.c` — must be byte-identical to `stage2.c` |

```bash
orinb compile compiler/main.or -o build/stage1.c && cc ... -o build/orin1
build/orin1 compile compiler/main.or -o build/stage2.c && cc ... -o build/orin2
build/orin2 compile compiler/main.or -o build/stage3.c
cmp build/stage2.c build/stage3.c
python3 tools/run_tests.py --orinc build/orin2
```

All stages share the CLI `<compiler> compile <entry.or> -o <out.c>` and the C runtime.
Generated C must not contain timestamps, absolute paths or hash-order-dependent output.
Stage equality is a consistency check, not a correctness proof (spec 09).

## Stage 1 layout (`compiler/`)

Each directory is a module (`module.or` = public API). Contracts written by the lead:
`diag/diag.or`, `syntax/ast.or`, `hir/hir.or` (mirrors of the Rust `span/diag`, `ast`, `hir`).
Components are ports of the Stage 0 Rust components with the same behaviour and diagnostics.

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
