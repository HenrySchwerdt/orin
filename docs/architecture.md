# Orin Compiler Architecture

Status: living document. Owner: lead architect. Normative source of language requirements is
`spec/`; this file records how the implementation realises them.

## Repository layout

| Path | Contents |
|---|---|
| `spec/` | Language/product specification (authoritative). |
| `docs/bootstrap-subset.md` | Frozen Orin-B subset compiled by Stage 0 and used to write Stage 1. |
| `docs/decisions/` | ADRs (interpretations of OPEN points, deviations). |
| `bootstrap/` | **Stage 0** compiler `orinb` in Rust (temporary). Orin-B → GNU C. |
| `runtime/` | C runtime `orin_runtime.{h,c}` shared by all stages' generated code. |
| `compiler/` | **Stage 1+** compiler written in Orin (`compiler/main.or`). |
| `tests/run/` | Conformance programs: `x.or` + expected stdout `x.out`. |
| `tests/errors/` | Must-fail programs; first line `// error: E0xxx`. |
| `tools/` | Test runner and bootstrap scripts. |

## Pipeline (Stage 0 and Stage 1 share the same shape)

```
file.or ──lexer/parser──▶ AST ──loader (imports, module rules, DAG)──▶ units (topo-sorted)
      ──checker (resolve + type)──▶ typed HIR ──codegen──▶ GNU C ──cc + runtime──▶ native exe
```

Stage 0 contracts are the Rust modules `span.rs`, `diag.rs`, `ast.rs`, `hir.rs`,
`loader.rs` (interface section). Changing them requires the lead architect.
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
- **Ownership convention in generated code (Stage 0):** function parameters are *borrowed*;
  return values are *owned* (+1); locals own their value; storing a borrowed value
  (into a local, field, array, return) retains it; owned temporaries that are only borrowed
  are released after use. Locals are released at scope exit (including `break`, `continue`,
  `return`). Early exits from inside an expression (`?`, diverging match arms) may leak
  already-evaluated temporaries — a leak, never a use-after-free. Counts must never be too low;
  too high only costs memory and extra copies.
- Checked arithmetic uses `__builtin_*_overflow`; traps call `orin_trap(msg)` → stderr
  `trap: msg`, exit 101.

## Safety status (honest labelling, spec 07)

| Property | Status |
|---|---|
| Bounds-checked indexing, checked arithmetic | Implemented in runtime/codegen; tested only |
| RC never under-counts (no UAF/double free) | Design rule; tested only (ASan runs planned) |
| Value semantics / COW | Tested only |
| Formal core calculus, proofs | Not started |
| OIM memory IR + independent verifier | Not started (milestone M4) |
