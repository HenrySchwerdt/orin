# ADR-0011: Closures and function values

Status: accepted (2026-10-13). Resolves spec-12 OPEN #2 (function parameter and closure
semantics) for the first implementation. Prerequisite for the spec-08 array API
(`map`, `filter`, `find`, `reduce`, `some`, `every`, `sort`).

## Syntax (TypeScript arrow functions; one canonical form)
```ts
const inc = (x: int): int => x + 1;           // expression body
const f = (x: int) => { return x * 2; };      // block body (return type inferred from returns)
const names = users.filter(u => u.active).map(u => u.name);  // param types from expected type
function apply(f: (x: int) => int, v: int): int { return f(v); }   // function type
const g = double;                              // top-level function used as a value
```
- Function types are written `(name: T, ...) => R` (parameter names are documentation only;
  types are compared structurally by parameter and result types).
- Parameter types may be omitted only when an expected function type is known (E0407 otherwise).
- No `function` expressions, no `this` binding, no default/rest parameters, no generic arrows.

## Semantics
- **Capture by value (snapshot):** a closure captures the *current values* of the outer locals it
  mentions, at creation time. Captured names are immutable inside the closure (assignment →
  E0401). Later mutation of an outer `let` does not affect the closure, and the closure cannot
  mutate the outer variable. This is the value-semantics rule of spec 03 applied to closures; it
  rules out shared mutable environments and therefore owning cycles (spec 06).
- A closure cannot refer to itself (no recursive arrows); use a top-level function.
- Function values are immutable, RC'd objects; no equality (`==` on function types → E0410).
- Evaluation: argument evaluation order and traps as for direct calls.
- Generic functions may be used as values only when instantiated by the expected type.
- Resource handles (future, spec 06) cannot be captured (rule to be enforced when resources exist).

## Implementation (as built)
- Syntax: `EArrow(params, ret, body)` / `TFn(params, ret)` (ast.or); `x => e` is one-parameter sugar.
  An arrow is parsed where an expression starts (`name =>`, or `( .. ) [: R] =>` found by matching the
  parenthesis); as a branch of `?:` it must be parenthesised. A function type is `(` followed by `)` or
  `name :`; other parenthesised types are grouping (`((x: int) => int)[]`).
- Checker (`check/body.or`, `check/fnctx.or`): an arrow body is checked as a *new function* (`FnCtx.outer` is a
  snapshot of the enclosing context). A name that is not a local there but is visible outside becomes a
  *capture*: an immutable local initialised at entry from the environment record (assignment, `push` or a
  mutating method call on it is E0401). After the body: environment record `<fn>$closureN$env`, lifted
  function `<fn>$closureN(env, params..)` (HIR registered in `Env.lifted`, `FuncInfo.mode 6`), and
  `XClosure(fn, captures)` in the enclosing function (captures are looked up there too, so nested closures
  capture transitively). Result type: declared, else the expected type's, else inferred (block bodies from
  their `return`s). Top-level functions used as values get a wrapper `f$closure`; a generic function needs
  its type arguments from the expected function type (E0407 otherwise).
- Generic inference: an arrow argument whose expected parameter types are known (not its result) is
  checked against them and its type binds the result parameter (`xs.map(x => x.name)`); an annotated
  parameter may stand for an unknown one (`reduce((acc: int[], x) => ..., [])`).
- MIR/backends: `IClosure` / `ICallIndirect` (docs/mir.md v1.3); C emission casts the code pointer to the type
  implied by the operand types; the LLVM emitter does the same with `call ptr %fp`. The legacy HIR->C
  backend rejects closure programs with an internal-error message (`--legacy-codegen`, exit 70).
- Array API: `array/array.or` (generic `map`, `filter`, `find`, `findIndex`, `some`, `every`,
  `reduce`, `forEach`, stable merge `sort`, and per-element-type `indexOf*` / `includes*` because a generic
  body has no `==`). It is a prelude root (spec 19 R1: `array/`, row in `PRELUDES` of `tools/embed_prelude.py`, `preludeRoots()`),
  loaded with every program as unit `$array/array`; unused instances are pruned (`opt/prune.or`); `xs.map(f)` is rewritten to a call of its function with the receiver as first argument.
  Methods return new values; `sort` takes `(a, b) => int` (negative, zero, positive).

## Original plan
- HIR: function types `TyFn(params, ret)`, closure creation `XClosure(fnId, captures)` and
  indirect call `XCallIndirect(callee, args)`; the checker performs closure conversion: each arrow
  becomes a lifted function whose first parameter is the environment record of captured values.
- MIR: `IClosure(dst, func, captures)` (captures consumed like `IStructNew`) and
  `ICallIndirect(dst, callee, args)` (callee and args borrowed; result Owned). Lifted functions
  take all parameters borrowed (owned-parameter inference does not cross indirect calls).
- Runtime: a closure is a struct object `{ code pointer (scalar slot), env (ref slot) }`.
- Array API as builtins with closure arguments; `sort(cmp)` returns a new array (spec 08).

## Note (added later)

The legacy HIR -> C backend (`--legacy-codegen`) mentioned above, and in ADR-0018, 0019, 0022 and 0025,
was removed in the first post-freeze cleanup PR; only the MIR backends (C, LLVM) remain.
