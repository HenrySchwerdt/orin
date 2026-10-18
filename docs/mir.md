# MIR and the OIM ownership verifier (v2.8; in/out receivers and `IArrayExtend` are v1.10, unboxed aggregates v2.2, load forwarding `IForward` v2.4, string append primitives v2.5, unchecked array access `IArrayGetU` / `IArraySetU` v2.6, unique receivers and results v2.7, unchecked struct slots `IGetFieldU` / `ISetFieldU` v2.8)

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
first argument. Network (ADR-0033, same version, additive): `Listener` and `Stream` are `MHandle` too. Openers `BGrantNet`
(`[host]`), `BGrantListen` / `BGrantConnect` (`[net, ..]`), `BNetListen` (`[net, addr, port, backlog, opt]`), `BNetAccept`
(`[listener, timeout, opt]`), `BNetConnect` (`[net, host, port, timeout, opt]`); closer `BNetClose` (a Listener or Stream; a
grant is closed by `BGrantRevoke`); uses `BNetStatus`, `BNetPort`, `BNetNow`, `BNetRecv`, `BNetSend`, `BNetShutdown`,
`BNetPeer`, `BNetResolve` (handle first) and `BNetErrorText`. `main` may have one `MHandle` parameter (the Host; the C / LLVM `main` passes `orin_cap_host_root()`).
v1.10 (performance) two additions, both produced only by the optimiser (`compiler/opt`): `IArrayExtend(x, y)`, array
concatenation in place (`x = x ++ y`, rules exactly those of `IStrAppend`), and **in/out receivers**: `MFunction.inout`
(parameter 0 is also an output) with the matching call and return rules (see "In/out receiver" below). The textual form
prints `(params 1, owned l0, inout)` and `arrayextend x, y`. New built-ins `BBytesToString` / `BStringToBytes`
(`bytesToString(u8[], start, len)`, `stringToBytes(s)`) need no MIR rule (built-ins have no signature table).

v2.3 (ADR-0038 class (e), reuse in place) one new instruction, `IStrPrepend(x, y)`: `x = y ++ x`, the consuming form of string
concatenation. The lowering emits it for `a + b` when `b` is an owned temporary that dies there and `a` is borrowed or a literal
(`"w" + n.toString()`): instead of copying `a` and appending `b` (two allocations), `b`'s buffer is extended at the front, in place
when `b` is unique (the runtime checks `rc == 1`; a shared `b` is copied and released, so value semantics and COW are unchanged).
Verifier rules are exactly those of `IStrAppend` (x is mutated, consumed and replaced: Owned/Unique/Imm, stays Owned; y live and
not `x`, not borrowed from `x`). Textual form `strprepend x, y`. The optimiser also gains a second `extendArrays` rewrite
(`d = concat(x, y); release x` becomes `arrayextend x, y; d = move x`, no new instruction): the release proves that `x` is owned and
dead after the concatenation, so `qs(lo).concat(eq)` extends the temporary `qs(lo)` instead of copying it.

v2.4 (ADR-0038 lever 2, T4) **load forwarding**: one new instruction, `IForward(d, s, o, key)`, textual form `d = forward s, o[key]`.
It means `d = s` (a scalar copy) and *claims* that the scalar local `s` holds the current value of slot `key` of the object `o` (a
field index written as a `usize` constant, `o[1u]`, or an array index operand, `o[l4]`). The optimiser (`compiler/opt/forward.or`) emits
it in place of the second `getfield` / `arrayget` of a scalar slot in a block. The verifier re-checks the claim with rule **F1**
(`compiler/verify/forward.or`, section "Load forwarding" below) and rejects an `IForward` it cannot justify, error text
`unjustified forward`. Forwarding is behaviour-only, not memory safety (an unjustified one reads a stale scalar, never a freed
object), but it is checked to the standard of ADR-0032 like every other fact the optimiser acts on. Both emitters print `d = s`;
`orin2 compile --assert-facts` additionally checks the claim at run time.

v2.5 (ADR-0038 addendum 2026-10-16, string intermediates) two new instructions, both with exactly the ownership rules of
`IStrAppend`: `IStrAppendNum(x, y, unsigned)` (`x = x ++ decimal(y)`, textual `strappendi x, y` / `strappendu x, y`) appends the
decimal text of the scalar `y` (an `int`, or a `usize` when `unsigned`) without building a string for it, and
`IStrAppendSub(x, y, a, b)` (`x = x ++ y[a..b]`, textual `strappendsub x, y, a, b`) appends the bytes `[a, b)` of the string `y`
(`a`, `b` usize scalars) without the substring object; it traps `substring out of range` exactly when `BStrSubstring` does
(`a > b` or `b > len(y)`). The lowering emits them for `s + n.toString()`, `${n}`, `s += n.toString()`, for a bare `n.toString()`
(`str.withCapacity(24)` then `strappendi`) and for the last piece of a string `+=` chain that is a `substring` (a left-nested
`s += a + b + c` is appended piece by piece, every piece evaluated first and in order, so the evaluation order and the traps are
those of the concatenation). Runtime: `orin_str_append_int` / `orin_str_append_usize` / `orin_str_append_sub` (in place only when
the destination has `rc == 1` and is not the source, otherwise a fresh string and the old one released, as `orin_str_append`).

v2.7 (ADR-0038 lever 2, T5) **unique receivers and results across calls**: two flags on `MFunction`, printed after the existing ones in the
function header (`fn7 Reader.next (params 1, owned l0, inout, unique-in, unique-out) -> int`): `unique-in` (the in/out receiver, local 0, is
`Unique` on entry) and `unique-out` (the value handed back is `Unique`: local 0 at each return of an `inout` function, the returned local of
any other function with a reference result). They are declarations that the verifier checks on both sides of every call (rules **U2-U5**,
section "Unique receivers and results" below); the emitters ignore them. No new instruction. (T5 was first built as v2.5; main took v2.5 and v2.6 for the string append primitives and unchecked access, so it is v2.7 here.)

v2.0 (ADR-0020 D3, rewrite step 3a) **source spans**: every instruction and every terminator carries the span of the HIR node it was
lowered from. `MBlock` is now `{ instrs; spans; term; termSpan }` (`spans[i]` belongs to `instrs[i]`, record invariant
`spans.length == instrs.length`); `noSpan()` (file index 4294967295) marks code without a source position (hand-written MIR, code the
optimiser invents from nothing). **No new instruction and no semantic change**: the verifier's verdicts are the same, the C and LLVM
output is byte-identical (the emitters ignore spans), the optimiser keeps the span of the instruction it rewrites (an inserted
`dup` / `release` has the span of the call or edge it belongs to). Text format: see "Source spans" below.

v2.1 (ADR-0017 stage 0, ADR-0027 Q10) tasks: **no new type or instruction**. One builtin `BTask(k)` (`compiler/hir/taskops.or`) carries the task
primitives (monitors, transfer tokens, thread start / join). Three of them touch handles: `grantClone` (k = 17, `[grant]` -> a handle of the same
family) is an opener like `BGrantUnder`; `grantMove` (k = 18, `[handle]` -> a `usize` token) is a CLOSER like `BGrantRevoke` (the handle must be `Open`,
is `Dead` afterwards: moved exactly once on every path, never a parameter); `grantAdoptFs / Process / Stdio / Clock` (k = 19..22, `[token]` -> a
handle) are openers whose argument is a scalar token: no argument may be a handle, the destination must be a bound handle local, and the function
must revoke it. A value sent to a task is consumed by the one-field record that carries it (`IStructNew`), which already kills every borrow of
the consumed local, so "no value used after it was moved into a task" is an existing rule; the runtime decides move or copy from the reference
counts. Cases: `compiler/tests/verify_main.or` (`taskGrantCases`).

v2.2 (ADR-0038 step 1, unboxing) **unboxed aggregates**: a new type `MAgg(n)` (printed `agg<n>`), an Option / Result / record / pair of
scalars held **by value** in n + 1 64-bit words (word 0 the tag, words 1..n the payload; 0 <= n <= 3, at most four words). It has no heap
object, no header and no reference count. Produced only by the optimiser (`compiler/opt/unbox.or`); no new instruction: the existing ones
take an aggregate where noted in "Unboxed aggregates" below. The verifier treats an aggregate as a scalar (`Init`).

v2.8 (ADR-0038 lever 2, T7) **unchecked struct slots**: two new instructions, `IGetFieldU(d, o, k)` (`d = getfieldu o.k`) and
`ISetFieldU(x, k, v)` (`setfieldu x.k = v`). Each means exactly `IGetField` / `ISetField` of a **heap struct** **without the check that the object
is a struct (kind 3) with more than `k` slots** (the C backend's `orinc_chk_slot`, the LLVM backend's `slotInline` guard): the backends read and write
`slots[k]` directly (`orinc_struct_get_u`, `orinc_struct_set_u` / `orinc_mir_struct_replace_u`; one `getelementptr inbounds`). The operand must be a
reference local (never an unboxed aggregate: that path has no header to check and is unchanged). Like U1 this is a **memory-safety** fact, so the
verifier rejects an unchecked access it cannot justify (rule **U6**, `compiler/verify/fieldcheck.or`, section "Unchecked struct slots" below, error
text `unchecked struct slot access without a dominating check`). The optimiser (`compiler/opt/fieldcheck.or`, its last pass) emits them where U6
accepts them; the lowering never does. Textual forms `l2 = getfieldu l0.1` and `setfieldu l0.0 = l3`. `ITakeField` / `IPutField` keep their check.
A third instruction, `IShapeCheck(o, k)` (`shapecheck l0.3`), traps with the shape message unless `o` is a struct with more than `k` slots, and does nothing
otherwise: the check of the first access of a block, on its own. The optimiser puts one in front of the first access of a struct local when later
accesses of the same block use higher slots, and then every access of the group is unchecked. Both backends emit just the existing guard
(`orinc_chk_slot`; the LLVM `slotGuardInline`).
`--assert-facts` does not re-run the omitted check for these (it would need a new runtime symbol; runtime/ and the seed are frozen for this change).
(v2.7 is T5, unique receivers and results.)

v2.6 (ADR-0038 lever 2, T2) **unchecked array access**: two new instructions, `IArrayGetU(d, a, i)` (`d = arraygetu a[i]`) and
`IArraySetU(x, i, v)` (`arraysetu x[i] = v`). Each means exactly `IArrayGet` / `IArraySet` **without the kind check and without the
bounds check**: the C backend reads and writes `items[i]` directly (`orinc_array_at_u`, `orinc_mir_array_put_u` / `orinc_mir_array_replace_u`),
the LLVM backend emits the `getelementptr inbounds` and no compare. Unlike `IForward` this is a **memory-safety** fact, so the verifier
rejects an unchecked access it cannot justify (rule **U1**, `compiler/verify/unchecked.or` and `compiler/verify/range.or`, section "Unchecked array
access" below, error text `unchecked array access without a dominating check or a range fact`). U1 has two fact sources: a **dominating
access** (T2: an earlier access of the same array and index in the same block passed both checks) and **interval facts** (T6: an interval
analysis of the whole function proves the index below the length of an array built by `arraynew` in the function). The optimiser
(`compiler/opt/bounds.or`, its last pass) emits them where U1 accepts them; the lowering never does. Textual forms `l3 = arraygetu l0[1u]` and `arraysetu l0[l4] = l2`. `orin2 compile --assert-facts` re-runs the
omitted checks before each one. (T2 was first built as v2.5; main took v2.5 for the string append primitives (PR #100), so it is v2.6 here.)

v2.4 (ADR-0044) `BStrWithCapacity(n)`: **no new instruction**. `IBuiltin(Some(d), BStrWithCapacity, [n: usize])` (printed `str.withCapacity`) defines `d` as a new, owned, unique, empty string with room for `n` bytes (runtime `orin_str_with_capacity`, `n` clamped to 1 MiB). The checker emits it only as the start of an OX markup root; the lowering then appends every piece in place (`IStrAppend`).

## Execution model
A function has locals (`MLocal`) and basic blocks; `blocks[0]` is the entry. Instructions execute
in order; each block ends in exactly one terminator. Scalars (`MInt`, `MUsize`, `MBool`, `MFloat`) are plain
values. `MRef` locals point to RC'd heap objects (runtime/core/orin_runtime.h). Runtime traps
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
  **v2.7:** a call of a `unique-in` function needs `Unique` for argument 0 (U4), and a call of a `unique-out` function defines its
  result (or, for an `inout` function, the receiver) `Unique` instead of `Owned` (U5). A call of an `inout` function demotes every
  `Unique` argument in a borrowed position whatever its result type (the callee may keep a counted reference to it in the receiver
  it hands back).
  Otherwise a call does not change argument states (borrowed for the call), **except** that a `Unique`
  ref argument is demoted to `Owned` when the call has a ref-typed result: the callee may return
  a retained alias of its argument, so uniqueness is no longer provable (found by the verifier;
  v1.1). Lowering must re-`IMakeUnique` before mutating such a local. The demotion applies to
  borrowed positions only (consumed operands are Dead afterwards).
- `IStrAppend(x, y)`: x Owned/Unique (stays Owned); y live.
- `IStrPrepend(x, y)` (v2.3): the same rules as `IStrAppend` with the roles of the operands in the result swapped (`x = y ++ x`).
- `IStrAppendNum(x, y, uns)` (v2.5): x Owned/Unique/Imm (stays Owned, borrows of x die); y is a scalar of class `int` (`usize` when
  `uns`), so it cannot alias x. `IStrAppendSub(x, y, a, b)` (v2.5): the rules of `IStrAppend` for x and y (y live, not x, not
  borrowed from x), `a` and `b` usize scalars. Well-formedness: x and y reference class, bounds usize class (`wf.or`).
- `IArrayExtend(x, y)` (v1.10): the same rules for arrays: x Owned/Unique (stays Owned: the runtime appends in place when x is
  unique and otherwise replaces it by a new array), y a live reference *local* that is neither x nor borrowed from x; the
  reference elements of y are retained by the runtime, y itself is not consumed. Borrows of x die.
- `IStructNew(d, tag, slots)`, `IArrayNew(d, isRef, elems)`: each ref operand Owned/Unique local
  (→ Dead) or OStr; d Unique.
- `INullary(d, t)`: d Owned (immortal).
- `IGetField(d, o, i)` / `IArrayGet(d, a, i)`: o live, slot i not a hole; ref d → `Borrowed(root(o))`.
- `IForward(d, s, o, key)` (v2.4): d and s plain scalars of one class (int, usize, bool, float), o a reference local, key a usize operand;
  s and o live, slot `key` of o not a hole; d `Init`. Rule F1 must justify the claim (below), else **error** `unjustified forward`.
- `IArrayGetU(d, a, i)` (v2.6): the rules of `IArrayGet`, and rule U1 must justify the omitted checks (below, by a dominating access or by
  interval facts), else **error** `unchecked array access without a dominating check or a range fact`.
- `IShapeCheck(o, k)` (v2.8): `o` live (a plain read; it defines nothing, kills no borrow and is no obstacle to a forward).
- `IGetFieldU(d, o, i)` / `ISetFieldU(x, i, v)` (v2.8): the rules of `IGetField` / `ISetField` for a reference local, and rule U6 must justify the
  omitted check (below), else **error** `unchecked struct slot access without a dominating check`.
- `ISetField(x, i, v)` / `IArraySet(x, i, v)` / `IArraySetU(x, i, v)` (v2.6, plus rule U1): x **Unique**; v consumed as for StructNew.
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

## Borrowed read-only copies of parameters (borrow inference, ADR-0038 class (d))
The lowering copies a reference parameter into a local (`d = dup p` ... `release d`). `compiler/opt/borrow.or` recognises the
copies that are only read and rewrites them to `d = borrow p` (no retain, no release), so that the parameter stays borrowed
(`paramOwned[p] = false`) and no caller retains its argument. **No new rule**: `IBorrow(d, p)` of a `Param` gives `Borrowed(Param)`,
valid for the whole call, and the uses the pass allows (field and element reads, builtins, borrowed call positions) are the uses
the verifier already accepts for a `Borrowed` local. A copy that is moved, stored, returned, retained again, mutated, or passed to an
owned position keeps its `dup` (default deny).

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
basic block with no redefinition of `x` / `v` in between (a `release` of `d` or of a local it was moved to may also be in a later block when the receiver was moved out: it then releases only `v`, v2.2), in which case the record is not built (`getfield d.0` -> `borrow x`,
`getfield d.1` -> `borrow v` / `copy v`, `release d` -> release of x and v, `t = getfield d.0; u = dup t` -> `u = move x`).
Mutation corpus: `inout-drop-receiver`, `inout-release-receiver` (tools/mutate_mir.py); hand-written cases:
`compiler/tests/verify_main.or` `inoutCases`. The Lean model covers the structured fragment without calls, so it is unaffected.

## Unique receivers and results (v2.7, ADR-0038 lever 2 T5, rules U2-U5)
A mutating method starts with `makeunique this`, a test of `rc == 1`, and after every in/out call the receiver is `Owned` again, so the
next call tests it again. v2.7 lets a function *declare* that it expects (`unique-in`) or promises (`unique-out`) a `Unique` value, and
the verifier checks the declaration on both sides. All four rules are local to one function or one call; there is no whole-program
fixpoint in the verifier.
- wf (`wf.or`): `unique-in` needs `inout` (only an in/out function has a receiver); `unique-out` needs `inout` or a reference result.
  `main` is not `unique-in` (the runtime calls it).
- **U2**, callee entry (`verify.or` `entryState`): if `unique-in`, local 0 starts `Unique` instead of `Owned`.
- **U3**, return (`rules.or` `uniqueReturn`): if `unique-out`, at every `TReturn` local 0 (`inout`) or the returned local (otherwise; an
  `OStr` or a missing operand is an error) must be `Unique`, else **error** `... not Unique (rule U3)`. Checked before the return consumes it.
- **U4**, call site: `ICall` of a `unique-in` function needs argument 0 `Unique` (`needUnique`), else **error** `... requires ... to be Unique`.
- **U5**, call result: after `ICall` of a `unique-out` function the destination is `Unique` (non-`inout`), or the receiver local that was
  redefined `Owned` is redefined `Unique` (`inout`).
- Demotion at calls (v1.1) is unchanged for non-`inout` callees. New in v2.7: an `inout` call also demotes its borrowed `Unique` arguments when
  the result is a scalar (see "Checked, not assumed" below).

Checked, not assumed. The soundness argument rests on three facts that were checked in the code, not taken from the ADR text:
1. *An `inout` function is never reached except by a direct `ICall`.* `IClosure` (`wf.or` `closureMsg`) and the vtable check
   (`verify.or` `vtableMsg`) both require every parameter to be borrowed, and an `inout` function has an owned parameter 0 (wf), so neither can
   name one. `ICallIndirect` and `ICallVirtual` only call closure and vtable targets. `main` is rejected as `unique-in`. So every call of a
   `unique-in` function is an `ICall`, and U4 covers all of them: U2's assumption holds at runtime.
2. *The receiver is the only reference at an `inout` call.* `Unique` means no other counted reference (`rc == 1` from this local) and no
   live `Borrowed` alias: every way to alias a `Unique` local demotes it (`IDup`, whole `IBorrow`, a closure/iface/struct that consumes it) or
   consumes it (which runs `killBorrows`); the call consumes argument 0 in an owned position, which kills every `Borrowed` alias of it
   (`consume` -> `kill` -> `killBorrows`), and a borrowed argument that is the receiver or an alias of it is already an error
   (`callOwned`). The callee's local 0 is therefore the only reference to the object. *Found while checking:* before v2.7 a `Unique`
   argument in a **borrowed** position stayed `Unique` after an `inout` call with a scalar or void result, although the callee may
   `dup` it and store the copy in the receiver it hands back (`push(items, item)` with a borrowed `item`). That made `Unique` unsound for
   such an argument (harmless while only a runtime `makeunique` consumed the fact, fatal once a callee skips the test). The rule now demotes
   every borrowed argument of an `inout` call; `compiler/tests/verify_main.or` `uniqueCases` has the case.
3. *A returned `Unique` local is not reachable from anything the callee keeps (U3 for a non-`inout` result).* The callee can keep nothing:
   there are no globals, a closure consumes what it captures, a callee cannot store into a borrowed parameter (`needUnique` rejects a store
   through a `Param`), and an owned parameter it consumes is gone. The only state that outlives the call is the `inout` receiver, and that
   case is covered by 2 (a stored copy was made by a `dup`, which demotes the original). `KUnique` is produced only by `IStructNew`,
   `IArrayNew`, `IClosure`, `IIface`, `IMakeUnique` (a fresh or sole object) and a move of a `Unique` local, and lost by every alias-creating
   instruction, so at a return it means the object has no other reference, and returning it hands the sole reference to the caller.
   U3 checks only the kind of the returned local, and that is enough.
Optimiser (`compiler/opt/uniqflags.or`): optimistic assumption and retraction. Candidates: an `inout` function whose block 0 starts with
the `makeunique` of its receiver is a `unique-in` candidate; an `inout` function or a function with a reference result is a `unique-out`
candidate when some caller can use the result (the local that receives it is, up to moves, made Unique or passed as a `unique-in`
receiver) and a flow-insensitive filter says its return is plausibly Unique. A worklist analyses each function with the must-analysis of
`opt/unique.or` (at most as permissive as the verifier) under the current flags, callees before callers: a `unique-out` with a non-`Unique`
return is retracted and its callers are analysed again; a `unique-in` with a call site **inside a loop** whose receiver is not `Unique` is
retracted. A call site outside every loop never costs the flag: a `makeunique` goes before the call (the callee starts with the
`makeunique` of its receiver, so the copy happens where the callee would have made it, `cow_copies` is unchanged, and it is paid once, not
per iteration). Flags only go from set to cleared. Compile-time budget (design gate: self-compile +1 %): a function without a loop is not
analysed, it gets the `makeunique` before every such call and `opt/unique.or` (T1) removes the redundant ones; a function with more than
12000 blocks times locals gets no `unique-out`, and a loop in it that calls a `unique-in` candidate removes that flag. `opt/unique.or` (T1)
also knows the entry state (U2) and the results of `unique-out` calls (U5), and drops the `makeunique` instructions they make redundant. The
result is verified like every pass output.
Mutation corpus (`tools/mutate_mir.py`, the callee's header seen by the mutated caller is edited too): `uniq-flag-flip-in` (`unique-in` on
a callee whose call site passes a receiver that is not `Unique`: U4), `uniq-flag-flip-out` (`unique-out` on a function that returns a
value that is not `Unique`: U3), `uniq-in-shared-caller` (`t = dup x` before a call of a `unique-in` function: U4), `uniq-out-then-dup`
(`t = dup x` after a call of a `unique-out` function, with a store through `x` after it: U5). Hand-written cases:
`compiler/tests/verify_main.or` `uniqueCases`; optimiser: `compiler/tests/opt_test.or` (T5 section). The Lean model has no calls, so
U2-U5 are outside it (docs/tcb.md "rules not yet in the model").

## Load forwarding (v2.4, ADR-0038 lever 2 T4, rule F1)
`d = forward s, o[key]` is accepted when a backward scan of **the same block**, over at most 64 instructions (`WINDOW` in `forward.or`),
finds the *source* before anything that could have changed the slot. Going back from the `forward`, each instruction is classified:
- **source** (accepted): a load of the slot `(o, key)` into `s` (`getfield`, `arrayget`, or an `IForward` into `s`: it was itself checked, so a chain
  of forwards is justified step by step), or a store of the local `s` into the slot (`setfield o.k = s`, `arrayset o[key] = s`). A load
  that overwrites its own index local (`i = arrayget o[i]`) is not a source: after it, `o[i]` names another element; it ends the scan. The slot is the
  same when the field index / array index is the same constant or the same local.
- **no change** (the scan goes on): an instruction that does not mention `o` (including calls and builtins that do not receive `o`: a live
  reference to `o` excludes an in-place write by the callee, which needs `rc == 1`); `IMakeUnique(o)` (a shallow copy keeps every slot);
  `ITag`, `IBorrow`, `IDup` of `o`; a load, store, take or put of a *provably different* slot (two different constants).
- **rejected** (`unjustified forward`): any other instruction that mentions `o` (a call or builtin that receives it, `arraypush` / `arraypop` /
  `arrayextend`, a move, a release, a consuming constructor ...), a write that may hit the slot (the same slot, or an index that is not provably
  different), a load of the slot into another local (the first access that touches the slot must be the source), a **definition of `s`, `o` or
  the key local** (a call of an in/out function defines its receiver), the start of the block, or 64 instructions without a source.
The rule is fail-closed: anything it does not know about and that mentions `o` ends the scan. Step 1 is deliberately conservative: a call that
receives `o` ends the window; a later step may let calls through once the Lean lemma "a live reference excludes in-place mutation" is merged.
Reference slots are not forwarded (`IBorrow(d, earlier)` would be accepted only while `earlier` is still a live borrow of `o`; the pass would need the
verifier's states at every position).
*Soundness argument.* The value of a scalar slot changes only through an instruction that stores into, takes from, puts into, grows or shrinks
the object `o` names, through an in/out call or a consuming call on a local that aliases it (impossible while `o` is live and the object is
shared: it needs `rc == 1`; this is the argument behind borrows, docs/tcb.md), or by redefining a local the claim depends on. The scan rejects the
first group and the redefinitions; the second is the existing ownership argument. Trap semantics: the forwarded access had already succeeded on
the same `(o, key)` in the same block, so its trap cannot fire; the checks stay where they are.
*Dynamic check.* `orin2 compile --assert-facts` (never on by default; C and LLVM backend) emits a call of
`orin_assert_fact(o, key, s)` **before** each `d = s` (runtime/core/orin_runtime.c). It uses the original object, key and source,
including when `d` is the key local. It reads the slot as the original `getfield` / `arrayget` would have and exits
**70** with `internal error: --assert-facts: a forwarded load differs from the slot it was forwarded from` if the value differs. The test suites run
under it (`run_tests.py --assert-facts`). Evidence, not proof (ADR-0032 addendum).
*Tests.* `compiler/tests/verify_main.or` `forwardCases`, `compiler/tests/opt_test.or` (T4 section). Mutation corpus (`tools/mutate_mir.py`, run on
every `forward` of the optimised conformance corpus): `fwd-across-write`, `fwd-other-slot-ok` (a positive control: a write to a different slot is
accepted), `fwd-after-redef-obj`, `fwd-after-redef-src`, `fwd-across-push`, `fwd-wrong-slot`, `fwd-across-block`.
Lean (`formal/Orin/Forward.lean`): `load_load` and `store_load` (a load after a load or store of the same slot, with no write and no
redefinition in between, returns the same value), `store_frame_other_slot`, `store_frame_other_local` (a store through another local cannot
change `o`'s slots in a well-formed state) and `makeUnique_frame` (`makeUnique` keeps every slot). They prove the facts F1 relies on in the
model; the Orin scan itself is not proved equal to them, and calls and array length are outside the model.

## Unchecked array access (v2.6, ADR-0038 lever 2 T2 and T6, rule U1)
`d = arraygetu a[i]` and `arraysetu a[i] = v` skip the two checks of the runtime (`orin_array_at`: the object is an array, `i < len`). Skipping
them is memory safety, so the verifier accepts one only with one of two facts. The first (**dominated-by-check**, T2), a backward scan of **the same block**, over at most 64 instructions (`WINDOW`,
`scan.or`, shared with F1), finds the access that already passed both checks, before anything could have changed the kind or the length of
the object. Going back from the unchecked access, for the array local `a` and the index operand `i`:
- **source** (accepted): the first `arrayget`, `arraygetu`, `arrayset` or `arraysetu` of the same array local and the same index (the same
  `usize` constant or the same local) that does **not define `a` or the index local itself**. `i = arrayget a[i]` (and `a = arrayget a[i]`)
  leaves `a[i]` naming another element, so it justifies nothing after it (the bug rule F1 had until review; U1 has a case for it).
- **no change** (the scan goes on): an instruction that does not mention `a` (including calls and builtins that do not receive `a`: a live local
  `a` holds a reference, so a callee cannot shrink the object in place, which needs `rc == 1`; the verifier already rejects giving one object to an
  in/out receiver and to another argument, rule `callOwned`); `IMakeUnique(a)` (a copy has the same kind and length); an `arrayget` / `arrayset` /
  `arraygetu` / `arraysetu` of **another index** of `a` (it changes no length); an `IForward` from `a`.
- **rejected**: any other instruction that mentions `a`: `arraypush`, `arraypop`, `arrayextend`, `arraytake`, `arrayput` (conservative: they do
  not change the length, but they are the instructions that open and close holes, and the ADR lists them), a call or builtin that receives `a`, a
  move, a release, a dup, a borrow, a consuming constructor; a **definition of `a` or of the index local** (a destination, a move, the
  receiver of an in/out call); the start of the block; 64 instructions without a source. Fail closed: anything the scan does not know that mentions
  `a` ends it.
Everything else is the ordinary rule: `arraygetu` is an `arrayget` (the slot must not be a hole, a reference result is `Borrowed`), `arraysetu` is
an `arrayset` (the array must be `Unique`). *Soundness.* The first access executed the kind and the bounds check on the object `a` holds; the
object a live local holds changes its kind never and its length only through the instructions the scan rejects, through a redefinition of the
local (rejected), or through an in/out call or a consuming call on an alias (impossible while `a` is live: it needs `rc == 1`; the argument
behind borrows, docs/tcb.md). *Trap semantics.* The removed check is an exact duplicate of one that passed with no length change since, so it
cannot fire; the first access keeps its check, in its place, with its message. No trap moves. The second fact (**interval**, T6) is the next subsection.
*Dynamic check.* `orin2 compile --assert-facts` emits `orin_assert_array(a, i)` (runtime/core/orin_runtime.c) before every unchecked access (C and LLVM;
the operands as they are before the instruction, so a destination that is the index local is fine); a failure exits **70** with
`internal error: --assert-facts: an unchecked array access ...`. The suites run under it. Evidence, not proof.
*Tests.* `compiler/tests/verify_main.or` `uncheckedCases` (accepted: get / set after get / set, local index, chain of unchecked accesses,
`makeunique`, another index, a store to the same element, a call that does not receive `a`, the window; rejected: no earlier access, another
constant / local index, another array, push, pop, extend, take, put, dup, redefinition, move, index redefinition, a call that receives `a`, an in/out
call, a source that redefines its own index (checked and unchecked, get and set), another block, beyond the window), `compiler/tests/opt_test.or`
and `emit_test.or` (T2 sections). Mutation corpus (`tools/mutate_mir.py`, every `arraygetu` / `arraysetu` of the optimised corpus, and every checked
access without an earlier one): `bce-no-fact`, `bce-across-push`, `bce-after-redef`, `bce-after-redef-index`, `bce-other-index`, `bce-across-block`,
and the positive controls `bce-makeunique-ok` and `bce-other-index-ok` (accepted; a rejection is a finding). Lean: array length is outside the
model (`formal/Orin/Machine.lean` has no arrays with a length), so U1 has no lemma; it is listed with the other rules not yet in the model
(docs/tcb.md, docs/formal.md), not claimed as proved.

## Unchecked struct slots (v2.8, ADR-0038 lever 2 T7, rule U6)
`d = getfieldu o.k` and `setfieldu o.k = v` skip the check of the runtime (`orin_struct_get` / `orin_struct_set`: the object is a struct and `k < nslots`).
The verifier accepts one only when a backward scan of **the same block**, over at most 64 instructions (`WINDOW`, `scan.or`), finds an earlier
`getfield`, `getfieldu`, `setfield`, `setfieldu`, `takefield` or `putfield` of the **same struct local** `o` with slot `k' >= k` (each of them traps unless
the object is a struct with more than `k'` slots, hence more than `k`), (or an `IShapeCheck(o, k')` with `k' >= k`, or the `IStructNew` that builds `o` with more than `k` slots: the slot count is known statically) with no instruction in between that **defines `o`** (a destination, a move, the
receiver of an in/out call) and no in-place string / array operation on `o` (fail closed). An access of a lower slot is no source but does not end the
scan. A source that defines `o` itself (`o = getfield o.k`) justifies nothing after it. *Unlike U1 nothing else ends the scan*: the kind and the slot
count of a struct are fixed by `IStructNew` and no instruction changes them, and the copy `IMakeUnique` makes of a shared struct has the same header,
so `makeunique`, takes and puts, stores, calls that receive `o` and any other use leave the fact intact. The operand must be a reference local
(`wf.or`); an unboxed aggregate is a different local type, so the source is a heap access of the same local. The ordinary rules apply to the
instruction itself (`getfieldu` is a `getfield`: a hole or a borrow is as for the checked form; `setfieldu` needs a `Unique` object).
*Trap semantics.* The removed check duplicates one that passed on the same object, so it cannot fire; the first access keeps its check, in its place.
*Tests.* `compiler/tests/verify_main.or` `fieldCases`, `compiler/tests/opt_test.or` and `emit_test.or` (T7 sections); mutation classes of
`tools/mutate_mir.py`: `field-no-fact`, `field-after-redef`, `field-across-block`, `field-higher-slot`, `shape-drop`, `shape-too-small` and the positive control `field-makeunique-ok`.
*Shape checks.* A trap that would have fired at a later, higher-slot access now fires at the shape check in front of the first access, with the same message; it
only concerns an object of the wrong shape, which is a compiler bug (docs/assurance.md), never a program error.
`verify_text --facts` reports `field-checked` / `field-none` per unchecked field access.

### Range facts (v2.6, ADR-0038 lever 2 T6, rules R1-R5)
The second fact source of U1, `compiler/verify/range.or`: a forward interval analysis of the whole function, independent of the ownership
state and of the optimiser (the verifier re-derives everything; the pass in `opt/bounds.or` only asks the same code). It runs only for a
function that accesses a local which an `arraynew` with at least one element defines (directly or through up to three moves) and whose
`locals x blocks` product is at most 4000 (a larger function is not analysed, which only means nothing there is interval-justified: the
fixpoint costs that product per edge, and the self-compile gate of +1 % did not allow more), once per function, and in the verifier only when an unchecked
access exists that the dominating-access scan did not justify.
- **R1 state.** Per local an interval `[lo, hi]` of mathematical integers (a `usize` unsigned). `lo = -2^60` as a lower bound and `hi = 2^60` as
  an upper bound mean *no bound* (a `usize` never has a lower bound below 0), so the verifier's own sums cannot overflow. For a reference local
  the interval is the **length** of the array it holds, and `lo >= 0` means *known to hold an array*: it is set only by `arraynew` with n
  elements (`[n, n]`) and carried only by `move`. Every other definition (a call result, a field, a parameter, a join with a path that has no
  fact) leaves the unknown interval, so **parameters and call results have no shape fact**.
- **R2 transfer.** `copy`, `move` and `forward` copy the interval; `add` and `sub` of two `int` or two `usize` operands add and subtract
  bounds with infinity absorbing; `arr.length(a)` of a known array gives its length interval, otherwise `[0, no bound]`; every other
  definition of a scalar local gives *unknown*. The overflow and underflow traps of the runtime stay: a `usize` subtraction continues with the
  results `>= 0` only, and one that always underflows ends the path (**no state**: nothing after it is justified). An array fact is destroyed by
  every instruction that mentions the array other than: `arrayget(u)` / `arrayset(u)` of it, `makeunique`, `forward` from it, `arr.length`, and a
  call of a known function that passes it only in **borrowed** positions (not the in/out receiver) and does not define it. So `arraypush`,
  `arraypop`, `arrayextend`, `arraytake`, `arrayput`, `dup`, `borrow`, `release`, a consuming constructor, a call that receives it owned or in/out,
  an indirect or virtual call, any other builtin, and every definition of the local destroy the fact. Why a borrowed call may keep it: a
  borrowed parameter is never pushed to, popped, taken from or made unique by the callee (those need an `Owned` local), and the caller's live
  reference makes every other holder copy before it writes (an in-place write needs `rc == 1`, docs/tcb.md).
- **R3 refinement.** A `lt`, `le`, `gt`, `ge`, `eq` or `ne` of two `int` or two `usize` operands defined in the block of a `TBranch` on its result,
  with neither operand nor the bool redefined since, refines both operands on each edge (`x < y`: `hi(x) <= hi(y) - 1`, `lo(y) >= lo(x) + 1`;
  `x <= y`; `x == y` both ways; the false edge is the negation; `ne` refines only its false edge). A bound that is *no bound* refines nothing. An
  edge whose refinement is empty is infeasible and carries no state.
- **R4 join.** Interval hull at joins. A block whose in-state changed more than twice widens the bound that moved to the nearest constant of
  the function beyond it (the constants the function uses, their neighbours and the array literal lengths) or to *no bound*; after the fixpoint
  **one narrowing round** recomputes every in-state, in block order, from the exit states of its predecessors (a block no feasible edge reaches
  becomes unreached). Every state before and after is an over-approximation of the executions that reach the block, so the round is sound
  whatever the widening lost.
- **R5 acceptance.** `IArrayGetU` / `IArraySetU` of `(a, i)` is accepted when the state before it is live, `a` is a known array, and
  `lo(i) >= 0` and `hi(i) < lo(length of a)` with `hi(i)` a real bound. A block the analysis does not reach, and the rest of a block after a
  dead point, justify nothing (fail closed).
*Soundness.* Each state describes every value the locals can hold at the point (induction over the steps: the transfer functions are sound for
the semantics above, the branch refinement uses only values that have not changed since the comparison, the joins and widening only enlarge). The
shape fact says the local holds the array `arraynew` built or a move of it; the length fact survives only instructions that cannot change the
length of the object a live local holds (the borrowed-call argument above). The index test then excludes both failures of the removed check
(the kind check cannot fail for an array; `i >= len` cannot happen). *Trap semantics.* Only checks proved unable to fire are removed; nothing
is hoisted; index arithmetic keeps its overflow and underflow traps (and a negative `int` cannot become an index: `toUsize` traps, and the index
operand of an array access must be a `usize`). *Not modelled.* Array length is outside the Lean model; R1-R5 have no lemma (docs/tcb.md,
docs/formal.md).
*Tests.* `compiler/tests/verify_main.or` `rangeCases` (accepted: constant and local indices, loops with every comparison form, a bound in a
local or the array length, nested loops, joins, the narrowing round, moved and borrowed-call arrays; rejected: a bound one too large with every
form, a missing, disturbed, earlier-block or `ne` guard, push, pop, extend, take, dup, borrow, consuming constructor, redefinition, owned and in/out
calls, an indirect call, parameters, call results, record fields, strings, unknown or huge indices, an always-underflowing path), `compiler/tests/opt_test.or`
(T6 section), the `tests/next/run/bce_range_*` programs (output identical to main; `--assert-facts` clean). Mutation corpus (`tools/mutate_mir.py`,
every unchecked access that only the interval fact justifies, found with `verify_text --facts`): `range-widen-off-by-one`, `range-after-push`,
`range-after-pop`, `range-across-dup`, `range-after-redef-array`, `range-after-inout-call`, `range-param-array`, `range-after-redef-index`,
`range-index-add-large`, `range-no-branch-refinement`, and the positive controls `range-move-roundtrip-ok`, `range-borrowed-call-ok`,
`range-copy-index-ok`, `range-addsub-ok`.

## Unboxed aggregates (v2.2, ADR-0038 step 1)
`MAgg(n)` is a value of n + 1 words: `w[0]` the tag, `w[1..n]` the payload. A payload is a sequence of *slots*: a scalar slot (int, usize,
bool, float: its 64-bit pattern, as in a heap slot) takes one word, a nested aggregate `MAgg(m)` its m + 1 words (tag included), in slot
order; unused words are zero. Instructions (anything not listed rejects an aggregate operand or destination, wf in `wf.or`):
- `IStructNew(d: MAgg(n), tag, slots)`: `d = { tag, the slots' words, zeros }`; every slot is a plain scalar or an aggregate (no reference,
  handle or string constant) and they fit into n words. `INullary(d: MAgg(n), tag)`: `{ tag, zeros }`.
- `ITag(d, o: MAgg(n))`: word 0. `IGetField(d, o: MAgg(n), k)`: **k is a word offset into the payload** (not a slot index): a plain scalar `d`
  reads word k + 1, an aggregate `d: MAgg(m)` the words k + 1 .. k + m + 1 (k + words(d) <= n).
- `ICopy(d, o)` between aggregates of the same width; call arguments and results (`ICall` only: the class comparison includes the width),
  `TReturn`; argument 0 of the Option / Result builtins (`isSome`, `isNone`, `isOk`, `isErr`, `unwrap`, `unwrapOr`, `unwrapErr`; the
  payload readers need n >= 1 and a plain scalar destination; the traps are those of the boxed builtins).
- `IArrayPop(d: MAgg(1), arr)`: `{ 0, element }` or `{ 1, 0 }` when empty; the runtime releases an element of a reference array (the
  optimiser only pops into an aggregate whose payload is read as a scalar or not at all).
- Never: `IMove` / `IBorrow` / `IDup` / `IRelease` (ownership), a slot of a heap object, an array element, a closure capture, an interface
  value, an argument or result of `ICallIndirect` / `ICallVirtual`, an operand of `IBinary`, an owned parameter, a local wider than four words.

Verifier: an aggregate local is `Init` once defined (parameters start `Init`); every read needs it defined (no join with `Dead`), nothing
else: no leak, no borrow, no uniqueness. Soundness: an aggregate contains no reference, so no rule about references depends on it; every
operation on it is a pure function of its words. The optimiser converts a value only when every instruction that touches it is one of the
above (default deny), so the program does the same calls in the same order and the retains / releases it drops are exactly those of the
heap object that no longer exists. Backends: C `OrinV<n>` (`typedef struct { uint64_t w[n + 1]; }`, `compiler/backends/c/preamble.or`), compound
literals, by-value parameters and results; LLVM `[n+1 x i64]` with `insertvalue` / `extractvalue`, by-value parameters and results. Unwrap
traps call `orin_v_unwrap(tag, word, what)`, pop calls `orin_array_pop_v(arr, out)` (both in `orin_runtime.c`). Cases:
`compiler/tests/unbox_test.or`.

## Source spans (v2.0)
`MBlock.spans[i]` is a `Span { file; start; end }` (byte offsets, `file` indexes the `SourceMap`) of the HIR expression or statement the
instruction was lowered from; `termSpan` is the span of the terminator. Rules of the lowering (`compiler/lower/lowerer.or`):

- an expression sets the span to its own while it is lowered and restores its parent's afterwards: the instructions of a call carry the
  span of the call, those of its arguments the spans of the arguments, the error path of `x?` the span of the `?` expression;
- a statement takes the span of its head expression (initializer of a `let`, value of an assignment, condition of `if` / `while`, the
  iterated array of `for`, the value of `return`); the fall-through `goto`s and releases at the end of a block keep the span of the last statement;
- `break`, `continue` and a bare `return` have no span in the HIR and keep the span of the statement before them; the epilogue of a function
  (end-of-body releases, the implicit `return`, `trap: missing return`) has the span of the function.

Verifier: `VerifyIssue` has a `span` (the span of the offending instruction; `noSpan()` for function-level well-formedness errors and for MIR without
spans). `orin compile` / `orin verify` print `verify error: <func> b<B> i<I> at <path>:<line>:<col>: <message>` when it has one.

Text format (`orin mir`, read back by `compiler/tests/verify_text.or`): an instruction or terminator line ends in ` @<file>:<start>-<end>`, e.g.
`release l1 @0:78-89`; a line without the suffix has no span. The parser also accepts MIR without any suffix.

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
The scope functions of `library/std/fs.or` and `library/std/host.or` are the only code that opens handles (the harness generated by `orin test` is the one exception: it derives the process grant of the test executable). Handles never enter RC bookkeeping.

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
Implementation: `compiler/verify/` (`wf.or` well-formedness, `state.or` abstract domain and joins (class `State`),
`rules.or` one transfer function per instruction/terminator (methods of class `Transfer`), `verify.or` worklist fixpoint
(class `Fixpoint`, which owns the worklist) and reporting). The structural predicates shared with the lowering are in
`compiler/mir/wellformed.or` (`isWellFormedFunction`, `isWellFormedProgram`, `instrInRange`, `termInRange`, ...); the
verifier's own check is independent of them, and its contracts state that it implies them (docs/rewrite.md, step 3b). Tests: `compiler/tests/verify_main.or` (hand-written cases), `compiler/tests/verify_text.or` (batch driver over textual MIR: differential test against the Lean checker, `tools/diff_verifier_lean.py`, and mutation corpus, `tools/mutate_mir.py`). Choices where the rules above were ambiguous:

- **Well-formedness first.** Index ranges, operand classes (int/usize/bool/ref), `ICall` arity and
  argument/return classes, `paramCount <= locals.length`, no `void` locals, one span per instruction (`spans.length ==
  instrs.length`), and a callee / closure target / vtable entry whose parameters are locals (checked at the use, since the
  callee itself may be checked later) (`OUsize` is a 64-bit pattern since v1.6: any int is well-formed). If a
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
  mutating op including `IPutField`/`IArrayPut`, `IStrAppend`, `IStrPrepend`, `IStrAppendNum` and `IStrAppendSub`. `IGetField`/`IArrayGet` of a
  borrowed object get the same root; of a Param the root is the Param itself. `Borrowed(x)` is
  also dead after `IMakeUnique(x)`, `IArrayPush`, `IArrayPop`.
- **Holes.** A hole key is a constant slot/index or a `usize` local used as array index
  (symbolic). Reads/takes/sets use a conservative "may alias" test (any symbolic key matches
  anything); `put` needs the identical key. Redefining a local that names an open hole is an
  error. *Any whole-object use* of an object with an open hole (call argument, `IDup`,
  `IBorrow`, move, release, consume, return, `IMakeUnique`, push/pop/`IStrAppend`/`IStrPrepend`/`IStrAppendNum`/`IStrAppendSub`) is an error:
  the callee/runtime would see an empty slot. `ISetField` into a taken slot is an error (use put).
- **Calls and uniqueness (rule strengthened).** The table says calls do not change argument
  states. That is unsound for `Unique`: a callee can return (a dup of) its argument, leaving a
  second reference to an object still believed Unique. The verifier therefore demotes a `Unique`
  local passed directly as an argument of an `ICall`/`IBuiltin` **whose destination is a
  reference** to `Owned` (re-establish with `IMakeUnique`). Scalar-result calls keep Unique.
- `IMakeUnique`/`IArrayPush`/`IArrayPop`/`IStrAppend`/`IStrPrepend`/`IStrAppendNum`/`IStrAppendSub` accept Owned/Unique/Imm; push/pop/append
  leave the local `Owned`, `IMakeUnique` leaves it `Unique`. `IStrAppend`/`IStrPrepend` reject `y` being `x`
  or borrowed from `x`.
- Not checked (no type information in MIR): field/slot index bounds, tags, `ITag`/`IGetField`
  on the right union, builtin signatures.

Flaws/gaps found in the rules: (1) call/Unique aliasing above; (2) the table does not say what a
whole-object use of an object with open holes means (treated as error); (3) "x Owned" vs `Imm`
(immortal values) and scalar `Init`/uninitialised tracking are not in the state table;
(4) hole identity for dynamic array indices is unspecified (symbolic keys, above);
(5) a discarded owned call result is an unreported leak.
