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

Interfaces describe module contracts. Prefer static dispatch; dynamic dispatch must be explicitly represented and have predictable runtime cost. **OPEN:** structural versus nominal conformance and how interfaces are implemented without trait complexity. Do not silently introduce Java-style implicit reference semantics via interfaces.

## Identity and resources

Ordinary classes do not have independently observable shared mutable identity. Database connections, socket handles and actors are not ordinary value-class instances. They MUST use special trusted resource/actor APIs with escape and lifetime validation (`06-memory-model-oim.md`). The compiler MUST prevent resource duplication through normal value copying.

## Observable behavior

Class lowering MUST preserve return values, mutations, exceptions/traps-as-specified, evaluation order, module visibility and resource effects. Generated methods undergo the same type and memory checks as handwritten functions.
