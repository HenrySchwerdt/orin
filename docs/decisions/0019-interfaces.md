# ADR-0019: Interfaces (nominal; static bounds and vtable-based dynamic values)

Status: accepted (2026-10-13). Implements the "Interfaces" row of ADR-0016 and resolves spec-12
OPEN #4 (structural vs nominal). Spec: `spec/03-values-classes-interfaces.md`. The compiler's own
source stays Orin-B; only the language it accepts grows.

## Language
```ts
interface Shape { area(): int; name(): string; }
export interface Named { label(): string; }

class Circle implements Shape, Named { ... }          // nominal conformance, one or more interfaces

function total<T extends Shape>(xs: T[]): int { ... xs[i].area() ... }   // (1) static bound
const s: Shape = new Circle(2);  const all: Shape[] = [new Circle(1), new Square(2)];  // (2) dynamic
```
- An interface declares **method signatures only** (`name(params): R;`). Fields, default method
  bodies, `extends` between interfaces, type parameters and `T extends A & B` are **E0408**.
- **Conformance is nominal.** For every `implements I` the checker requires, for each interface
  method, a public instance method of the class with identical parameter types and result type. A
  missing or mismatching method is **E0417** (the message shows the required and the found
  signature). A class that does not declare `implements I` never converts to `I` and never satisfies
  a bound `T extends I`, even if it is structurally compatible (E0417 at the use site).
- **Non-mutating only (1.0 core).** Calling an interface method never mutates its receiver, so a class
  method that implements an interface method must be non-mutating; if the (inferred, ADR-0009)
  mutability of the implementing method is "mutating" the class gets **E0418**. Mutating interface
  methods are post-1.0.
- **Static use.** `<T extends I>`: one bound, an interface. The abstract check of the generic body
  (ADR-0007) gives the opaque `T` the methods of `I` (`x.area()` is allowed, nothing else is). Every
  instantiation (a call, an explicit `f<C>(..)`, a function value) checks the bound: the argument
  must be a class that implements `I`, the interface `I` itself, or an opaque parameter bounded by
  `I` (E0417 at the call). Instances are monomorphised as before, so `x.area()` becomes an ordinary
  static call: zero cost.
- **Dynamic use.** An interface name is a type (`Shape`, `Shape[]`, `Option<Shape>`, a parameter,
  a field). A value of a class type `C` converts **implicitly** to every interface that `C`
  declares (`const s: Shape = circle`). This is the only implicit conversion in the language; it
  applies wherever a value is checked against an expected type (initialisers, arguments, returns,
  assignments, array elements, record fields, `Some(..)`); it is not applied element-wise to arrays
  (`Circle[]` is not a `Shape[]`). There are no downcasts and no `instanceof` in 1.0 core; `==`/`!=` on
  interface values is **E0410**. Methods are called as `s.area()`.
- **Value semantics.** An interface value holds a *snapshot* of the class value (the conversion
  consumes/retains the reference exactly like storing the value into a record field; later
  mutation of the original goes through copy-on-write and is not observable through the interface
  value). Interface values are immutable.

## Representation and cost (explicit, ADR-0016)
An interface value is a struct object `{ vtable pointer (scalar slot 0), boxed class value (reference
slot 1) }`. A **vtable** is a static table of function pointers, one per (class, interface) pair
that the program converts, entries in interface-method order; the entries are the class methods
themselves (receiver first, all parameters borrowed). Cost: one allocation per conversion and one
indirect call per method call; nothing for bounds.

## Pipeline changes
- Syntax: `IInterface(InterfaceDecl)`, `ClassDecl.impls`, `FunctionDecl.bounds` (parallel to
  `typeParams`); `interface` is already a reserved word, `implements` is contextual.
- Checker: `TypeEnt.EntIface`, `Env.ifaces`, `Env.bounds` (opaque record -> interface), `Env.vtables`;
  conformance checks after mutation inference; conversion in `expect`; calls on interface values.
- HIR: `TyIface(id)`, `XIface(vtable, value)`, `XCallVirtual(recv, slot, args)`, `Program.vtables`.
- MIR (docs/mir.md v1.4, contract change): `IIface(dst, vtable, value)` (consumes `value` exactly
  like a one-slot `IStructNew`/`IClosure`), `ICallVirtual(dst, recv, slot, args)` (everything
  borrowed, like `ICallIndirect`), `MProgram.vtables`. Vtable targets keep all parameters borrowed
  (optimiser), are never pruned, and are checked by the verifier's well-formedness pass. C and LLVM
  emit static tables; the legacy HIR->C backend rejects interfaces like closures.
- Tooling: formatter, astdump, semantic index (go to definition from a method call or a class's
  `implements` entry to the interface/method declaration; hover on an interface lists its
  implementations), LSP and MCP `inspect`.

## As built
- Checker phases: `collect` registers `EntIface` and rejects generic / extending interfaces (E0408);
  `resolveDecls` resolves method signatures (`check/ifaces.or`); `resolveImpls` turns `implements` names into
  ids (E0300 unknown, E0400 not an interface, E0304 listed twice); after mutation inference `checkImpls`
  reports E0417 / E0418 and stops the pipeline.
- Bounds: the abstract check of `function f<T extends I>` gives `T` an opaque record registered in `Env.bounds`
  (so `x.m()` becomes a virtual-call placeholder whose HIR is discarded, as for every abstract check);
  `checkBounds` runs at every instantiation site, including function values and explicit `f<C>(..)`.
- Conversion: `expect` (the single place where an expression is checked against an expected type) calls
  `coerce`; `?:` with an interface context converts each branch. `Env.vtables` interns one vtable per
  (class, interface) pair; `withEnv` keeps it when closure bodies create one.
- `Program.ifaces` carries interface and method names for tooling only; backends need only the vtables.
- Semantic index: `SkInterface` defs with their methods as children, `SemanticIndex.impls` (class ->
  interface links), references from `implements` entries, bounds, interface-typed values' method calls
  (`virtRef`) and, inside instances of bounded generic functions, calls on `T` (they point at the interface
  method, not at the method of whichever class the instance was made for). LSP `textDocument/implementation`,
  MCP `inspect` (`implementedBy` / `implements`), document symbols and completion keywords.
- VS Code grammar: `class`/`interface`/`new`/`this` are no longer flagged as illegal reserved words;
  `implements`/`extends` are keywords.

## Out of scope (post-1.0)
Generic interfaces, default methods, interface inheritance, multiple bounds, mutating interface
methods, downcasts, interface values in `==`, structural conformance.
