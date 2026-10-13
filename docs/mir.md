# MIR and the OIM ownership verifier (v1.3)

Normative companion to `compiler/mir/mir.or`. Status: contract defined; implementation in
progress. Relation to spec 07: MIR is the *memory IR* layer; the verifier is the independent
checker of its ownership discipline. It is deliberately small and does not trust the lowering.

Changelog: v1.1 Unique-demotion across calls; v1.2 (ADR-0010) per-parameter modes
(`MFunction.paramOwned`) and consuming call operands, produced by the optimiser `compiler/opt`;
v1.3 (ADR-0011) closures: `IClosure` and `ICallIndirect`;
v1.4 (ADR-0018) floats: scalar type `MFloat` (binary64; an f32 is an MFloat rounded by `IBuiltin(BF32Round)` after each operation), operand `OFloat(text)`; `IUnary(UnNeg)` and `IBinary` Add/Sub/Mul/Div/Eq/Ne/Lt/Le/Gt/Ge accept MFloat operands (IEEE, no traps; `Rem` does not); conversions and math are `IBuiltin`s; floats are plain scalars for the verifier (`Init`), stored in slots by bit pattern.

## Execution model
A function has locals (`MLocal`) and basic blocks; `blocks[0]` is the entry. Instructions execute
in order; each block ends in exactly one terminator. Scalars (`MInt`, `MUsize`, `MBool`) are plain
values. `MRef` locals point to RC'd heap objects (runtime/orin_runtime.h). Runtime traps
(overflow, bounds, unwrap) are safe outcomes.

## Abstract ownership state (per `MRef` local, per program point)
| State | Meaning |
|---|---|
| `Dead` | uninitialised, moved out, or released — must not be read |
| `Owned` | holds one counted reference; must eventually be released, moved, consumed or returned (a leak is reported as a warning, not an error — leaks are memory-safe) |
| `Unique` | `Owned` and known to be the only reference (after `IMakeUnique`, `IStructNew`, `IArrayNew`) |
| `Borrowed(src)` | uncounted alias, valid while `src` is live and unmodified; `src` is a local or `Param` |
| `Param` | **borrowed** parameters: borrowed from the caller for the whole call |

Parameters have a mode, `MFunction.paramOwned[i]` (one flag per parameter; `false` = borrowed, the
default and all that lowering emits). An **owned** reference parameter starts `Owned` (not `Param`):
the callee holds one counted reference and must consume (move/store/return) or release it exactly
like any Owned local; leaking it is a warning. Scalar parameters are never owned.

Plus per-local **hole sets** (slot indices taken by `ITakeField`/`IArrayTake` not yet put back).

## Instruction rules (preconditions → effect). "read x" requires x ∉ {Dead}; for refs also not a
hole slot when reading that slot.
- `ICopy(d, o)`: o scalar or `OStr` → d scalar / Owned-immortal (OStr never needs release).
- `IMove(d, s)`: s Owned/Unique → d gets s's state, s Dead.
- `IBorrow(d, s)`: s live → d `Borrowed(s)` (or `Borrowed(root)` if s is itself borrowed).
- `IDup(d, o)`: o live → d Owned.
- `IRelease(x)`: x Owned/Unique → Dead. Releasing Param/Borrowed/Dead is an **error**.
- `ICall`/`IBuiltin`: all ref args live (any of Owned/Unique/Borrowed/Param/OStr); d Owned.
  **v1.2:** an `ICall` operand in an *owned-parameter position* (`callee.paramOwned[i]`) is
  CONSUMED: Owned/Unique/Imm local -> Dead (and its `Borrowed` aliases die), `OStr` allowed,
  Borrowed/Param (a borrowed parameter of the caller) is an **error**; a local consumed twice in one
  call is an error (second use is Dead). A borrowed-position operand of the same call may not be the
  consumed local or a `Borrowed` alias of it (the callee could release the object while reading the
  alias): **error**. `IBuiltin` operands are all borrowed (no builtin takes ownership).
  Otherwise a call does not change argument states (borrowed for the call), **except** that a `Unique`
  ref argument is demoted to `Owned` when the call has a ref-typed result: the callee may return
  a retained alias of its argument, so uniqueness is no longer provable (found by the verifier;
  v1.1). Lowering must re-`IMakeUnique` before mutating such a local. The demotion applies to
  borrowed positions only (consumed operands are Dead afterwards).
- `IStrAppend(x, y)`: x Owned/Unique (stays Owned); y live.
- `IStructNew(d, tag, slots)`, `IArrayNew(d, isRef, elems)`: each ref operand Owned/Unique local
  (→ Dead) or OStr; d Unique.
- `INullary(d, t)`: d Owned (immortal).
- `IGetField(d, o, i)` / `IArrayGet(d, a, i)`: o live, slot i not a hole; ref d → `Borrowed(root(o))`.
- `ISetField(x, i, v)` / `IArraySet(x, i, v)`: x **Unique**; v consumed as for StructNew.
  Effect: invalidates every `Borrowed(x)` local (→ Dead) because the old slot value is released.
- `ITakeField(d, x, i)` / `IArrayTake(d, x, i)`: x Unique; i not already a hole → d Owned, i added
  to holes(x); invalidates `Borrowed(x)` locals.
- `IPutField(x, i, s)` / `IArrayPut(x, i, s)`: x Unique, i ∈ holes(x), s Owned/Unique → s Dead,
  i removed from holes.
- `IClosure(d, f, caps)` (v1.3): the captured values are consumed exactly like the slots of
  `IStructNew` (Owned/Unique local → Dead, `OStr` allowed, Borrowed/Param is an **error**; scalars are
  read); d Unique. `f` must be a function whose first parameter is a reference (the environment record
  holding the captures, in order) and whose parameters are **all borrowed** (wf error otherwise; the
  optimiser never makes the parameters of an `IClosure` target owned). Runtime layout: a closure is a
  struct `{ code pointer (scalar slot 0), environment (reference slot 1) }`.
- `ICallIndirect(d, c, args)` (v1.3): the callee `c` (a reference local holding a closure) and all `args`
  are **borrowed** for the call (read, any live state); the callee is invoked as `f(env, args..)`; the
  result d is Owned (references) or initialised (scalars). As for `ICall`, a `Unique` operand is demoted
  to `Owned` when the call has a reference result. MIR has no signature for indirect calls, so only
  operand classes are checked (callee must be a reference local); the checker guarantees the types.
- `IMakeUnique(x)`: x Owned/Unique → Unique; invalidates `Borrowed(x)` locals (the object may be
  replaced).
- `IArrayPush(x, v)` / `IArrayPop(d, x)`: x Owned/Unique (→ Owned: the runtime may reallocate);
  invalidate `Borrowed(x)`; v consumed; d Owned.
- Any operation that makes x Dead or mutates it also invalidates `Borrowed(x)`.
- `IDup(d, x)` / `IBorrow(d, x)` where x is Unique demote x to Owned (no longer provably unique).

## Terminators
- `TReturn(Some(o))`: ref o must be Owned/Unique (→ consumed) or OStr. At every return, no local
  may be Unique/Owned other than the returned one (else **leak warning**), and no hole may be open
  (**error**: a hole would leave a dangling slot).
- `TBranch`/`TSwitch`: operand scalar and live.
- `TTrap`: no obligations (the process exits).

## Joins
At a CFG join, states must agree per local, except: {Owned, Unique} join to Owned; any state
joined with Dead is an **error** if the local is used later, otherwise Dead (lowering should
release on all paths). Borrowed(src) must have equal src on all paths. Hole sets must be equal.

## Soundness argument (informal; formalisation: docs/formal.md)
If every function verifies, then (1) every read targets a reference that is counted by some live
owner (Owned/Unique local, a Param's caller-side owner, or the root of a Borrowed chain which is
not mutated/released while the borrow is live) — hence no use-after-free; (2) every release
decrements a count owned by the releasing local exactly once — hence no double free;
(3) in-place writes happen only on Unique objects — hence aliases keep observing old values
(value semantics, spec 03). Assumptions (TCB): the runtime implements the operations as specified;
the C compiler and allocator are correct; the MIR → C emitter is a direct translation.

## Verifier implementation notes
Implementation: `compiler/verify/` (`wf.or` well-formedness, `state.or` abstract domain and joins,
`rules.or` one transfer function per instruction/terminator, `verify.or` worklist fixpoint and
reporting). Tests: `compiler/tests/verify_main.or` (hand-written cases), `compiler/tests/verify_text.or` (batch driver over textual MIR: differential test against the Lean checker, `tools/diff_verifier_lean.py`, and mutation corpus, `tools/mutate_mir.py`). Choices where the rules above were ambiguous:

- **Well-formedness first.** Index ranges, operand classes (int/usize/bool/ref), `ICall` arity and
  argument/return classes, `paramCount <= locals.length`, no `void` locals, `OUsize >= 0`. If a
  function is not well-formed only these errors are reported (no dataflow). `IBuiltin` has no
  signature table in MIR, so only its operand/destination indices are checked.
  `IMove`/`IBorrow`/`ITakeField`/`IArrayTake`/`IArrayPop` need distinct source and destination;
  `ICopy` of a reference *local* is rejected (use `IMove`/`IDup`/`IBorrow`); `IMove` is
  reference-only.
- **States.** Besides the five of the table: `Init` (initialised scalar), `Imm` (immortal
  reference: `OStr` copy or `INullary`; readable, consumable, releasable, never a leak, not
  Unique), and two poisoned join results `MaybeDead` / `MaybeLeak` (MaybeLeak: some path owns a
  reference). Parameters start `Param` (refs) or `Init` (scalars); all other locals `Dead`.
  Owned reference parameters start `Owned`. Parameters (scalar ones too) can never be redefined
  (an owned parameter may be moved/consumed/released, just not assigned).
  Well-formedness adds: `paramOwned.length == paramCount`, owned parameters are references.
- **Joins** are a semilattice join: identical states stay; Owned-like (Owned/Unique/Imm) join to
  Owned; every other disagreement (Dead vs anything, differing `Borrowed(src)`, Owned vs
  Borrowed, ...) is *poisoned*. "Error if used later, otherwise Dead" is implemented lazily: any
  read, release or consume of a poisoned local is an error at that use; redefining it repairs it.
  Hence mismatched `Borrowed` sources are only an error when the local is used after the join
  (slightly more permissive than the table, harmless since an unused alias is never dereferenced).
  A poisoned MaybeLeak local still yields a leak warning at `TReturn`. Hole sets join to the
  union, and the *edge* is reported as an error if the sets of the predecessor and the successor
  differ. Unreachable blocks are only checked for well-formedness. Termination: in-states only
  grow in a finite lattice (see `verify.or`).
- **Leaks (warnings):** at `TReturn` any local still Owned/Unique/MaybeLeak, and any definition
  that overwrites a local that may still own a reference. A discarded reference result
  (`ICall(None, ..)` of a ref-returning function) is *not* flagged (no obligation tracked).
- **Invalidation** of `Borrowed(x)` happens on release, move/consume, redefinition, and on every
  mutating op including `IPutField`/`IArrayPut` and `IStrAppend`. `IGetField`/`IArrayGet` of a
  borrowed object get the same root; of a Param the root is the Param itself. `Borrowed(x)` is
  also dead after `IMakeUnique(x)`, `IArrayPush`, `IArrayPop`.
- **Holes.** A hole key is a constant slot/index or a `usize` local used as array index
  (symbolic). Reads/takes/sets use a conservative "may alias" test (any symbolic key matches
  anything); `put` needs the identical key. Redefining a local that names an open hole is an
  error. *Any whole-object use* of an object with an open hole (call argument, `IDup`,
  `IBorrow`, move, release, consume, return, `IMakeUnique`, push/pop/`IStrAppend`) is an error:
  the callee/runtime would see an empty slot. `ISetField` into a taken slot is an error (use put).
- **Calls and uniqueness (rule strengthened).** The table says calls do not change argument
  states. That is unsound for `Unique`: a callee can return (a dup of) its argument, leaving a
  second reference to an object still believed Unique. The verifier therefore demotes a `Unique`
  local passed directly as an argument of an `ICall`/`IBuiltin` **whose destination is a
  reference** to `Owned` (re-establish with `IMakeUnique`). Scalar-result calls keep Unique.
- `IMakeUnique`/`IArrayPush`/`IArrayPop`/`IStrAppend` accept Owned/Unique/Imm; push/pop/append
  leave the local `Owned`, `IMakeUnique` leaves it `Unique`. `IStrAppend` rejects `y` being `x`
  or borrowed from `x`.
- Not checked (no type information in MIR): field/slot index bounds, tags, `ITag`/`IGetField`
  on the right union, builtin signatures.

Flaws/gaps found in the rules: (1) call/Unique aliasing above; (2) the table does not say what a
whole-object use of an object with open holes means (treated as error); (3) "x Owned" vs `Imm`
(immortal values) and scalar `Init`/uninitialised tracking are not in the state table;
(4) hole identity for dynamic array indices is unspecified (symbolic keys, above);
(5) a discarded owned call result is an unreported leak.
