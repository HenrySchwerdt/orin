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

## Implementation
- HIR: function types `TyFn(params, ret)`, closure creation `XClosure(fnId, captures)` and
  indirect call `XCallIndirect(callee, args)`; the checker performs closure conversion: each arrow
  becomes a lifted function whose first parameter is the environment record of captured values.
- MIR: `IClosure(dst, func, captures)` (captures consumed like `IStructNew`) and
  `ICallIndirect(dst, callee, args)` (callee and args borrowed; result Owned). Lifted functions
  take all parameters borrowed (owned-parameter inference does not cross indirect calls).
- Runtime: a closure is a struct object `{ code pointer (scalar slot), env (ref slot) }`.
- Array API as builtins with closure arguments; `sort(cmp)` returns a new array (spec 08).
