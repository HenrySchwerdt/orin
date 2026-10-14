# MIR and the OIM ownership verifier (v1.10)

Normative companion to `compiler/mir/mir.or`. Status: contract defined; implementation in
progress. Relation to spec 07: MIR is the *memory IR* layer; the verifier is the independent
checker of its ownership discipline. It is deliberately small and does not trust the lowering.

Changelog: v1.1 Unique-demotion across calls; v1.2 (ADR-0010) per-parameter modes
(`MFunction.paramOwned`) and consuming call operands, produced by the optimiser `compiler/opt`;
v1.3 (ADR-0011) closures: `IClosure` and `ICallIndirect`;
v1.4 (ADR-0018) floats: scalar type `MFloat` (binary64; an f32 is an MFloat rounded by `IBuiltin(BF32Round)` after each operation), operand `OFloat(text)`; `IUnary(UnNeg)` and `IBinary` Add/Sub/Mul/Div/Eq/Ne/Lt/Le/Gt/Ge accept MFloat operands (IEEE, no traps; `Rem` does not); conversions and math are `IBuiltin`s; floats are plain scalars for the verifier (`Init`), stored in slots by bit pattern.
v1.5 (ADR-0019) interfaces: `IIface`, `ICallVirtual` and `MProgram.vtables`.
v1.6 (ADR-0022) fixed-width integers: **no new type or instruction**. `i64`, `isize` and the narrow integers `i8 i16 i32 u8 u16 u32` are `MInt` (the value sign-/zero-extended), `u64` and `usize` are `MUsize`; `OUsize(n)` is the 64-bit *pattern* of the constant (a negative `n` is a value above 2^63-1; the old `OUsize >= 0` well-formedness rule is gone). After `+ - * /` and `-` on a narrow type the lowering emits `IBuiltin(BIntRange, [v, OInt lo, OInt hi])` (traps "integer overflow" outside the range); explicit conversions are `BIntConv` / `BUIntConv` / `BIntId`, `wrapping*` / `saturating*` / `checked*` are `BIntOp` / `BIntChk`, `parseI32` etc. are `BParseIntK` (operand constants carry the kind, see `hir.or`). Built-ins have no MIR signature, so the verifier needs no new rule.
v1.7 (ADR-0024) `MProgram.inlineFns`: the names of the `@Inline` functions, a backend hint (C `static inline`, LLVM `alwaysinline`) with no effect on the verifier or on semantics.
v1.8 (ADR-0025) resource handles: scalar type `MHandle`, builtins `BFileOpen` / `BFileClose` / `BFileIsOpen` /
`BFileOpenError` and the file methods, verifier states `Open` / `MaybeOpen` (see "Resource handles" below).
v1.9 (ADR-0021 Stage A, ADR-0027) capability grants: **no new type or instruction**. A grant is an `MHandle` with exactly the
discipline of a file handle. New builtins: the openers `BGrantFs` / `BGrantProcess` / `BGrantStdio` / `BGrantClock`
(`[host]`), `BGrantUnder` (`[fs, path]`), `BGrantReadOnly` (`[fs]`), `BGrantArgsOnly` (`[proc]`), the closer `BGrantRevoke`.
`BFileOpen` is now `[fs, path, mode]`, and every std I/O builtin (`BFsReadFile`, `BFsWriteFile`, `BFsExists`,
`BProcessArgs`, `BIoShell`, `BIoReadBytes`, `BIoReadLine`, `BIoWriteStdout`, `BTimeNowMillis`) takes its grant as the
first argument. `main` may have one `MHandle` parameter (the Host; the C / LLVM `main` passes `orin_cap_host_root()`).
v1.10 (performance) two additions, both produced only by the optimiser (`compiler/opt`): `IArrayExtend(x, y)`, array
concatenation in place (`x = x ++ y`, rules exactly those of `IStrAppend`), and **in/out receivers**: `MFunction.inout`
(parameter 0 is also an output) with the matching call and return rules (see "In/out receiver" below). The textual form
prints `(params 1, owned l0, inout)` and `arrayextend x, y`. New built-ins `BBytesToString` / `BStringToBytes`
(`bytesToString(u8[], start, len)`, `stringToBytes(s)`) need no MIR rule (built-ins have no signature table).

## Execution model
A function has locals (`MLocal`) and basic blocks; `blocks[0]` is the entry. Instructions execute
in order; each block ends in exactly one terminator. Scalars (`MInt`, `MUsize`, `MBool`, `MFloat`) are plain
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
- `IArrayExtend(x, y)` (v1.10): the same rules for arrays: x Owned/Unique (stays Owned: the runtime appends in place when x is
  unique and otherwise replaces it by a new array), y a live reference *local* that is neither x nor borrowed from x; the
  reference elements of y are retained by the runtime, y itself is not consumed. Borrows of x die.
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
- `IIface(d, vt, v)` (v1.5): the boxed value `v` is consumed exactly like a slot of `IStructNew` (Owned/Unique
  local → Dead, `OStr` allowed, Borrowed/Param is an **error**); d Unique. `vt` indexes `MProgram.vtables`.
  Runtime layout: a struct `{ vtable pointer (scalar slot 0), boxed value (reference slot 1) }`; the vtable
  pointer is the address of a static table of function pointers.
- `ICallVirtual(d, r, slot, args)` (v1.5): the interface value `r` (a reference local) and all `args` are
  **borrowed** for the call; the callee is `vtable[slot]`, invoked as `f(boxed, args..)`; the result d is
  Owned (references) or initialised (scalars). As for `ICall`/`ICallIndirect`, a `Unique` operand is demoted
  to `Owned` when the call has a reference result. MIR has no signature for virtual calls, so only operand
  classes are checked; the checker guarantees the types.
- `IMakeUnique(x)`: x Owned/Unique → Unique; invalidates `Borrowed(x)` locals (the object may be
  replaced).
- `IArrayPush(x, v)` / `IArrayPop(d, x)`: x Owned/Unique (→ Owned: the runtime may reallocate);
  invalidate `Borrowed(x)`; v consumed; d Owned.
- Any operation that makes x Dead or mutates it also invalidates `Borrowed(x)`.
- `IDup(d, x)` / `IBorrow(d, x)` where x is Unique demote x to Owned (no longer provably unique).

## In/out receiver (v1.10)
A mutating method with a result returns a fresh record `{ self, value }` (ADR-0009): one allocation, one retain and one release
per call for a value that never escapes. The optimiser (`compiler/opt/pairs.or`) removes it with a second kind of function:
`MFunction.inout = true` means that **parameter 0 is an owned reference that is also an output**. The function returns its own
result (`ret`, any type except a handle) as usual and hands the value that local 0 holds at each `TReturn` back to the caller,
which stores it in the local it passed as argument 0. In C this is `T f(OrinObj *l0, .., OrinObj **out)` with
`*out = l0; return v;` at each return and `&x` at the call; in the LLVM backend a `ptr` parameter and the address of the alloca.

Rules (wf in `wf.or`, dataflow in `rules.or`):
- wf: an `inout` function has `paramCount >= 1` and `paramOwned[0]` (so local 0 is a reference). A call of an `inout` function has
  a *local* as argument 0 (not `OStr`), and its destination (if any) is not that local.
- Callee: local 0 starts Owned like any owned parameter and may be moved from, consumed or released. It is the **only parameter
  that may be written** (`IMove(0, a)`, any destination rule applies as for other locals: overwriting an Owned value is a leak
  warning). At every `TReturn` it must be Owned/Unique/Imm (it is consumed: handed to the caller), otherwise **error** ("must hold
  the updated receiver"); an open hole in it is the usual error. It is not a leak.
- Call: `ICall(dst, g, [x, ..])` with `g.inout`: argument 0 is consumed exactly like any owned-position operand (Owned/Unique/Imm
  -> Dead, its borrows die; a Param or Borrowed operand is an **error**), and then `x` is redefined **Owned** (not Unique: the
  callee may have kept an alias). Redefining a parameter of the caller is an error except local 0 of an `inout` caller.
- An `inout` function is never a closure target or a vtable entry (the optimiser does not convert those; `wf` of `IClosure` and the
  vtable check require borrowed parameters anyway).

Soundness argument: for a verified caller and callee the pair `(x consumed, x redefined Owned)` is the same ownership transfer as
`r = call f(x); x = r.self` (the record's first slot owns one reference, the callee's final local 0 owns exactly one), without the
record. The optimiser only converts a function whose every return is `r = struct tag0 {a, v}; [releases]; return r` with `a` a
reference local and local 0 Dead at that point, so converting changes no count: `a` is moved into local 0 where the record
consumed it, and `v` is returned where the record consumed it. Call sites are rewritten to `v = call f(x, ..)` followed by the
record rebuilt (`d = struct tag0 {x, v}`) unless every use of `d` is a `getfield d.0|1`, `release d` or a move of `d` inside one
basic block with no redefinition of `x` / `v` in between, in which case the record is not built (`getfield d.0` -> `borrow x`,
`getfield d.1` -> `borrow v` / `copy v`, `release d` -> release of x and v, `t = getfield d.0; u = dup t` -> `u = move x`).
Mutation corpus: `inout-drop-receiver`, `inout-release-receiver` (tools/mutate_mir.py); hand-written cases:
`compiler/tests/verify_main.or` `inoutCases`. The Lean model covers the structured fragment without calls, so it is unaffected.

## Resource handles (v1.8, ADR-0025)
`MHandle` is the type of a resource handle (an open file): an `int64_t` at run time (a generation-tagged table
index, negative for a failed open), but a *linear, non-copyable* value for the verifier. Operand class `CHandle`.

Structural rules (wf, checked on every instruction, independent of the dataflow):
- a handle local is defined **only** by `IBuiltin(Some(h), <opener>, [authority, ...])` where the opener is `BFileOpen`
  or a `BGrant*` builtin and its first argument is the handle that authorises it (v1.9); the other arguments are not
  handles (the handle must be bound: `None` is an error, it would never be closed). `ICopy`, `IMove`, `IBorrow`, `IDup`, `IUnary`,
  `IBinary`, `ICall`/`ICallIndirect`/`ICallVirtual` results, `IGetField`, `IArrayGet`, ... never define one;
- a handle is never stored or boxed: not a slot of `IStructNew`, an element of `IArrayNew`, the value of
  `ISetField` / `IArraySet` / `IArrayPush`, a capture of `IClosure`, nor the value of `IIface`;
- never compared (`OpEq`/`OpNe` on handles), never a `TBranch`/`TSwitch` operand, never returned, and no function has
  result type `MHandle`; no parameter is *owned* (owned parameters are references);
- it is an argument of `ICall` / `ICallIndirect` / `ICallVirtual` (borrowed; `ICall` still checks the class
  against the callee's parameter) and the first argument of the file builtins (`BFileIsOpen`, `BFileOpenError`,
  `BFileClose`, `BFileReadLine`, `BFileRead`, `BFileReadAll`, `BFileWrite`, `BFileWriteLine`, `BFileFlush`), of the
  std I/O builtins listed in v1.9 and of `BGrantRevoke`; no other builtin accepts one, and these builtins take no
  handle after the first argument.

Dataflow rules (states in `state.or`): a handle local starts `Dead`; a handle *parameter* starts `Param`
(borrowed for the whole call, like a reference parameter).
- `BFileOpen -> h` and every `BGrant*` opener `-> h`: `h` becomes `Open` (the authorising first argument is read: it
  must be `Open` or `Param`, so a derived handle cannot outlive its parent within a function); if `h` was `Open`/`MaybeOpen` it is an **error** (overwritten while open:
  the file would never be closed); a parameter cannot be a destination (existing rule).
- `BFileClose(h)` / `BGrantRevoke(h)`: `h` must be `Open`, then `Dead`; closing a `Param`, a `Dead` or a `MaybeOpen` handle is an
  **error** (only the function that opened it closes it, and exactly once).
- any other use (call argument, file builtin): `h` must be `Open` or `Param` (reading a `Dead`/`MaybeOpen` handle is
  an error: use after close).
- `TReturn`: an `Open` or `MaybeOpen` handle is an **error** (not a warning like a leaked reference): every path
  that returns must have closed it. `TTrap` has no obligation (the runtime's exit hook flushes and closes).
- join: `Open` with `Open` is `Open`; `Open` with anything else is the poisoned `MaybeOpen`; `Dead` with `Dead` stays
  `Dead`. (`MaybeOpen` is an error to use, close or return with, so a handle opened on one branch only must be closed
  on that branch.)

Consequence (induction over the call graph): a function that receives a handle can only pass it on; only the
function that opened it can close it; it is closed exactly once on every path to a return and not used afterwards.
The scope functions of `stdlib/fs.or` and `stdlib/host.or` are the only code that opens handles (the harness generated by `orin test` is the one exception: it derives the process grant of the test executable). Handles never enter RC bookkeeping.

## Vtables (v1.5)
`MProgram.vtables[i] = { name, funcs }`: the functions of one (class, interface) pair in interface-method
order. Well-formedness (checked once per vtable by the verifier, whether or not an `IIface` uses it): every
entry is a function index in range, its first parameter is a reference (the boxed class value) and **all its
parameters are borrowed** (`paramOwned` all false). The optimiser never makes the parameters of a vtable entry
owned and never prunes it (compare closure targets); C and LLVM emit each table as a constant array.
A function may be both an `ICall` target and a vtable entry (a class method called directly and through an
interface).

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
  argument/return classes, `paramCount <= locals.length`, no `void` locals (`OUsize` is a 64-bit pattern since v1.6: any int is well-formed). If a
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
  (an owned parameter may be moved/consumed/released, just not assigned), except local 0 of an `inout`
  function (v1.10, "In/out receiver").
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
