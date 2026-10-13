# 03 — Values, Classes, and Interfaces

## Value semantics by default

Records and ordinary classes are **values**. Copying a binding yields a logically independent snapshot. The compiler MAY share immutable storage or perform copy-on-write; observable mutations must behave as if separate values existed. This is a semantic rule, not an instruction to copy all bytes eagerly.

```typescript
class Counter {
  constructor(public value: int) {}
  increment(): void { this.value += 1; }
}
let a = new Counter(0);
const b = a;
a.increment();
// a.value == 1, b.value == 0
```

`const` disallows assignment and state-changing methods on its value. `let` permits local reassignment and mutation, but does not imply shared mutable identity. Methods that modify `this` are logically lowered to `Counter_increment(oldCounter) -> Counter` and rebound to the mutable receiver. Compiler MAY update in place only if no observable alias changes. The compiler MUST reject mutating a `const` receiver and MUST preserve snapshot semantics.

## Classes

- `class` provides named fields, constructors, methods, `public`/`private`, static methods, encapsulation and validation of invariants.
- Default calls dispatch statically; lower a class to record/data representation plus functions.
- Class inheritance is initially forbidden. Prefer composition and interfaces.
- No runtime reflection or dynamic class redefinition by default.
- Named records and classes are nominally typed; their field shapes alone do not make them equivalent.
- **OPEN:** exact constructor field shorthand and static class initialization lifecycle.

```typescript
export class User {
  constructor(public id: int, private name: string) {}
  displayName(): string { return this.name; }
}
```

## Interfaces

Interfaces describe module contracts (ADR-0016 decision, ADR-0019 implementation). Conformance is **nominal**,
dispatch is explicit and its cost documented; there is no Java-style implicit reference semantics.

```typescript
interface Shape {
  area(): int;
  name(): string;
}

class Circle implements Shape, Named {            // conformance is declared, never inferred
  constructor(public r: int) {}
  area(): int { return 3 * this.r * this.r; }
  name(): string { return "circle"; }
}
```

- An interface lists **method signatures only**: no fields, no default methods, no inheritance between
  interfaces, no type parameters (E0408 for each).
- `class C implements I` requires, for every method of `I`, a public instance method of `C` with identical
  parameter and result types (E0417 otherwise, naming the missing or mismatching signature). A class that
  does not declare `implements I` does not conform even if it has all the methods (E0417 at the use).
- **Interface methods are non-mutating** in 1.0 core: calling one never changes its receiver. A class whose
  implementing method is (inferred) mutating is rejected (E0418). Mutating interface methods are post-1.0.
- **Static use: generic bounds.** `function total<T extends Shape>(xs: T[]): int` lets the body call the methods of
  `Shape` on a `T`. The body is checked once with an abstract `T` (only the interface methods and conversion to
  `Shape` are available) and instantiated by monomorphisation, so calls are static: zero cost. Every
  instantiation checks the bound (E0417 at the call): the argument must be a class declaring `implements Shape`,
  `Shape` itself, or a parameter bounded by `Shape`. One bound per parameter; `T extends A & B` is E0408.
- **Dynamic use: interface-typed values.** `const s: Shape = new Circle(2);`, `Shape[]`, `Option<Shape>`,
  parameters, fields and results of type `Shape`. A value of a class type **converts implicitly** to every interface
  its class declares: this is the *only* implicit conversion in the language. It applies wherever a value is checked
  against an expected type (initialisers, arguments, `return`, assignment, array elements, record fields,
  `Some(..)`/`Ok(..)`, branches of `?:` and `match` arms with a known target type); it is not lifted over
  arrays (`Circle[]` is not a `Shape[]`, E0400) and it does not chain (an interface value converts to no other
  interface or class: no downcasts and no `instanceof` in 1.0 core).
- **Representation and cost.** An interface value is a heap object `{ vtable pointer, boxed class value }`. The
  vtable is a static table of function pointers per (class, interface) pair; a call is one indirect call, a
  conversion is one allocation. **Value semantics hold**: the box holds a snapshot of the class value (later
  mutation of the original is not observable), and interface values are immutable.
- `==` / `!=` on interface values is E0410 (no identity, no structural equality).

## Identity and resources

Ordinary classes do not have independently observable shared mutable identity. Database connections, socket handles and actors are not ordinary value-class instances. They MUST use special trusted resource/actor APIs with escape and lifetime validation (`06-memory-model-oim.md`). The compiler MUST prevent resource duplication through normal value copying.

## Observable behavior

Class lowering MUST preserve return values, mutations, exceptions/traps-as-specified, evaluation order, module visibility and resource effects. Generated methods undergo the same type and memory checks as handwritten functions.
