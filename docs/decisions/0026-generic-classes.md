# ADR-0026: Generic classes

Status: accepted (2026-10-13). Implements the "Generic classes" row of ADR-0016 (the last item before the
language freeze) and removes the "no generic classes" limit of ADR-0009. Builds on ADR-0007 (generics by abstract
check + monomorphisation), ADR-0009 (classes), ADR-0019 (interfaces). The compiler's own source stays Orin-B.

## Language
```ts
class Box<T> {
  value: T;
  constructor(v: T) { this.value = v; }
  get(): T { return this.value; }
  set(v: T): void { this.value = v; }        // inferred mutating, like every method
}
class SortedList<T extends Ranked> { ... }   // bound: an interface (ADR-0019), one per parameter
class Wrapper<T> implements Shape { ... }    // a non-generic interface

const a = new Box<int>(1);                   // explicit type arguments always work
const b = new Box("s");                      // inferred (below)
const c: Box<Box<int>> = new Box(new Box(1));
```
- **Type arguments of `new`** follow the rules of generic function calls (ADR-0007): explicit list; else the expected
  type; else the constructor arguments (left to right, bare integer literals last, default `int`). A parameter that
  stays unbound is E0407. The class used as a type needs all its arguments (`Box` alone: E0400).
- **Multiple parameters, nesting, storage.** `Pair<A, B>`, `Box<Box<int>>`, `Map<string, Box<float>>`, `Box<int>[]`,
  `Option<Box<T>>`, recursive shapes (`left: Option<Tree<T>>`). `>>` is never a token (the lexer emits single `>`), so
  nested closers need no splitting; `>>` stays reserved for a post-1.0 shift.
- **Bounds** `class C<T extends I>`: the class body sees `T` as an opaque type with the methods of `I`; every
  instantiation (`new C<X>`, a type annotation, an inferred argument, a nested use) checks the bound (E0417: the
  argument must be a class declaring `implements I`, `I` itself, or a parameter bounded by `I`). An unknown or non-
  interface bound is E0300 / E0400.
- **`implements`** a (non-generic) interface: conformance is checked once on the abstract signatures; a signature that
  mentions `T` can never match (E0417); mutating implementations are E0418. Interface values of different
  instantiations mix freely; each (instance, interface) pair gets one vtable.
- **Contracts** (ADR-0012): `@Invariant`, `@Requires`, `@Ensures`, `old(..)` on the class and its methods. Expressions are
  checked once with opaque type parameters, so they may use `T`-typed values only as every type allows (E0410 for `==`
  on a `T`, E0405 for methods that the bound does not provide); with `--check-contracts` the runtime checks exist per
  instantiation. Contracts are erased otherwise.
- **Not supported (1.0).** *Generic methods* (`map<U>(..)`): E0460. *Static methods using the class type parameters*:
  E0461 (a static method has no instance and therefore no type arguments, as in TypeScript; it may still return or
  take any concrete instantiation such as `Pair<int, int>`). Generic interfaces, multiple bounds, default type
  arguments, inheritance stay post-1.0 / never.

New codes: **E0460** generic method, **E0461** static method mentions a class type parameter. Everything else reuses
codes: E0400 (arity), E0407 (cannot infer), E0417/E0418 (bounds, conformance), E0408 (record literal of a class outside
its body), E0413 (instantiation limit, e.g. polymorphic recursion `new R<T[]>` inside `R<T>`), E0450 (resource as a type
argument).

## Implementation: lowering to generic records and generic functions
ADR-0009 lowers a class to a record plus functions; a generic class lowers to a **generic record** `type C<T> = {..}`
plus **generic functions** `C.constructor<T>`, `C.m<T>(this$: C<T>, ..)` (all carrying the class type parameters and
bounds). Static methods lower to ordinary functions. Collection, abstract checking, inference and monomorphisation are
therefore the existing machinery of ADR-0007: **no HIR, MIR or backend change** (docs/mir.md stays v1.8).
- `ClassInfo.gid` is the generic record (`-1` for ordinary classes); `GenFunc.mode/cls` carry the ADR-0009 mode (1
  constructor, 2 method, 3/4 mutating) and the class, and `instFunc` gives every instance that mode (for mode 4 it
  creates the per-instance `$ret` record). `classOfRec` recognises instance records through their origin.
- Call dispatch (`classMethodCall`, `new`, vtables) resolves the receiver's instance, takes its type arguments and
  instantiates the generic method on demand (`methodSigOf`); abstract checks and mutation probes only compute the
  signature (no instances are created in a scratch environment).
- `implements` lists are resolved before declaration resolution, because instantiating a bounded class checks its
  bound while the declarations are still being resolved (`instType` -> `checkClassBounds`).
- **Mangled names** (HIR, C symbols): record `unit.Box<int>`, `unit.Pair<int,string>`, `unit.Box<unit.Box<int>>`;
  functions `unit.Box.get<int>`, `unit.Box.constructor<string>`; the `$ret` record of a mutating method with a result
  `unit.Stack.pop<int>$ret`. Arguments are rendered without spaces, deterministically, in discovery order.
- **Inferred mutation per instantiation.** A type parameter supports no mutating operation (only the non-mutating
  methods of its bound), so whether a method mutates `this` cannot depend on the type arguments. It is inferred
  **once**, by the ADR-0009 fixpoint over the abstract bodies (probe mode, opaque `T`), and every instance inherits the
  result; instances are therefore consistent by construction. It is part of the API snapshot like for ordinary classes:
  hover, `orin api`, MCP `inspect` and OSIG show `mut method push(x: T): void`. Because an unused generic method has no
  instance function, the checker exports the inferred table as `Program.mutating` (tooling only).
- **`?` in mutating methods with a result** (also ordinary classes): the early `Err` return must carry the receiver
  (`$ret { self, value }`). `x?` there is hoisted like a mutating call (before its statement; E0408 in conditional
  operands). Before this change such a program crashed at run time.

## Tooling
- Parser: `ClassDecl.bounds`; formatter prints bounded parameters and `new C<..>(..)`; astdump `(tparams T:Bound)`.
- Semantic index / LSP: one class symbol, one symbol per method; hover on the class shows `class Cell<T extends Shape>`;
  definition, references and rename on members of any instance reach the generic declaration; calls on a bounded
  `T` inside instances point at the interface method.
- **OSIG (ADR-0023): one node per generic declaration.** Instantiations are not symbols: `Stack<int>` and `Stack<string>`
  are the single node `pkg:mod::Stack`, calls from every instance are attributed to the declaration's methods (one
  edge, deduplicated), the `sig` carries the parameters (`class Bag<T extends Shape>`, `mut method push(x: T): void`),
  a call on a bounded `T` is `MUST` to the interface method plus `MAY` to the implementations (as for generic
  functions). Ids are unchanged in form, so they stay stable and readable.
- MCP `inspect`, VS Code grammar (no change needed: `class`, `new`, `extends` already highlighted).

## `std:graph`
Rewritten on `class Graph<T>` (see docs/std.md): generational, tagged `GraphId<T>`, stale or foreign ids are `Err`. The
functional stop-gap API (`newGraph`, `add(g, v)`, ...) is **removed**; all its tests were migrated.

## Limitations
No generic methods (E0460), static methods cannot use `T` (E0461), one bound per parameter, interface bounds only,
no generic interfaces. Instances are created on demand, so an instance method that is never called is checked only
abstractly. As for ordinary classes, a mutating call (and now a `?` in a mutating method) is evaluated before the rest
of its statement.
