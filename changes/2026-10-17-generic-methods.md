- **Generic methods and `void` as a type argument (ADR-0040).** Methods of classes and generic classes can declare their
  own type parameters (`m<U extends Eq>(x: U)`, inferred or explicit `obj.m<int>(x)`), are monomorphised per
  (class instance, method, type arguments) and have their contracts checked per instance; generic static methods are
  allowed but must not mention class type parameters. Interface methods stay non-generic (E0460). `void` is accepted as
  a type argument (`run(() => { ... })`, `Option<void>`, `Result<void, E>`, `void[]`, `Box<void>`); instances drop their
  void slots at lowering. `void` as a value, variable or parameter type is still an error.
- **`std:task` uses generic methods and `void` (ADR-0040).** `s.spawn(f)` is a method of `Scope`; `spawn`, `spawnDo`
  and the `scope*Do` functions are `@Deprecated` wrappers for one release. `scope(...)`/`s.spawn(...)` accept a void
  body (`TaskHandle<void>`). The runtime accepts the zero-slot box of a void transfer.
