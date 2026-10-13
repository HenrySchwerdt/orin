# ADR-0009: Classes (spec 03) — syntax subset and lowering

Status: accepted (2026-10-13). Resolves spec-12 OPEN #3 (class mutability) for the first
implementation; constructor shorthand partially resolved.

## Syntax (TypeScript-familiar)
```ts
export class Counter {
  value: int;                 // field declaration (optionally `= init` with a literal/expression)
  private label: string = "";
  constructor(value: int) { this.value = value; }
  increment(): void { this.value += 1; }   // mutating method (inferred, see below)
  get(): int { return this.value; }        // non-mutating method
  static zero(): Counter { return new Counter(0); }
}
let a = new Counter(0);  const b = a;  a.increment();   // a.value == 1, b.value == 0
```
Also accepted: TS parameter properties `constructor(public value: int, private name: string) {}`.
`public` is the default for members; `private` members are accessible only inside the class body.
No inheritance (`extends` → E0408), no `protected`, no getters/setters, no overloads, no
`abstract`, no generic classes/methods yet (E0408), no class expressions. `this` outside a class
→ E0300.

## Semantics
- A class is a **nominal value type** (spec 03): copies are snapshots; no shared identity.
- Constructor: every field must be definitely assigned before the constructor returns and before
  `this` is used other than as `this.f = e` (conservative rule: only top-level `this.f = e;`
  statements of the constructor body before any other use of `this` count; otherwise E0411).
- **Mutating methods are inferred**: a method mutates if its body assigns to a `this` place, calls
  a mutating builtin on a `this` place (`this.items.push(x)`), or calls a mutating method on
  `this`/a `this` place (fixpoint over the class). Calling a mutating method requires the receiver
  to be a mutable place (rooted in a `let` local, or `this` inside a mutating method) — else
  E0401 (spec 12 acceptance test: "Mutation through const receiver fails type checking").
- `this` in a non-mutating method is immutable (assigning to it is E0401).

## Lowering (in the checker; HIR and backends unchanged)
- Class `C` → HIR record `C` (fields: parameter properties first, then declared fields, in order).
- `new C(args)` → call of generated function `C.constructor(args): C` which builds the record.
- Non-mutating method `m(args): R` → function `C.m(this: C, args): R`; call `x.m(a)` → `C.m(x, a)`.
- Mutating method `m(args): void` → `C.m(this: C, args): C` returning the updated value;
  call `p.m(a)` on place `p` → `p = C.m(p, a)`.
  Mutating method with result `R` → returns a generated record `C.m$ret { self: C; value: R; }`;
  call → `{ const t = C.m(p, a); p = t.self; t.value }`.
- Static method → plain function `C.s(args)`; call `C.s(a)`.
- Performance: the receiver is passed and returned; with owned-parameter inference and last-use
  moves (ADR-0010) the update is in place when unshared. Before ADR-0010 lands, each mutating
  call may copy the object shallowly (correct, slower).

## Amendment (2026-10-13): explicit `mut` marker
Mutating methods are **declared** with the `mut` modifier (`mut withdraw(amount: int): void`)
instead of being inferred. Reason: whether a method mutates its receiver is part of the class's
public API (spec 04 API snapshots, spec 15 frame conditions); inference would let a body edit
silently change which call sites are legal. Rules: assigning to a `this` place, calling a mutating
builtin on a `this` place, or calling a `mut` method on `this` inside a non-`mut` method → E0401
with a hint to add `mut`; `mut` on a static method or constructor → E0400. Calling a `mut` method
requires a mutable receiver place (unchanged). Lowering is unchanged.
