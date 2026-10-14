# ADR-0040: Generic methods and `void` as a type argument

Status: accepted (2026-10-14, project owner). Language extension after the freeze; it is additive, so no existing
program changes meaning. Related: ADR-0026 (generic classes; E0460 "no generic methods in 1.0"), ADR-0016 (freeze,
changes only through an ADR), ADR-0017 (`std:task`), ADR-0033 (`std:net`), docs/rewrite.md.

## Context

The rewrite and the new std modules hit two gaps again and again. Each gap forces duplicated or less natural APIs:

| Gap | Today | Forced workaround |
|---|---|---|
| no generic methods (E0460) | `s.spawn<T>(f)` is rejected | the free function `spawn(s, f)` instead of a method; `Graph<T>` helpers as free functions |
| `void` cannot instantiate a type parameter | `run<T>(f: () => T)` with a `void` closure is E0407 (T not inferable) | twin APIs: `scope` / `scopeDo`, `spawn` / `spawnDo`, `TaskHandle<T>` / a void handle |

Both gaps are plain absences, not safety rules. The third gap the workers met, that a closure cannot capture a
resource handle (E0450–E0452), **is** a safety rule. It stays, and it is out of scope here (see "Not in scope").

## Decision

### 1. Generic methods

```ts
class Scope {
  spawn<T>(f: () => T): TaskHandle<T> { ... }
}
const h = s.spawn(() => fib(30));   // T = int, inferred as for generic functions
```

- **Where:** methods of classes and of generic classes may declare their own type parameters, including bounded
  ones (`<T: Ord>`, ADR-0019). Inference and explicit arguments work as for generic functions:
  `s.spawn<int>(...)`.
- **Implementation by monomorphisation,** like generic functions:
  - an instance is keyed by (class instance, method, type arguments);
  - the instance cache in `check/` (`Insts`) is extended by the method key;
  - the MIR is unchanged, because an instance is an ordinary function.
- **Not on interfaces:** an interface method with its own type parameters is still rejected.
  - **Reason:** a virtual call cannot pick a monomorphised instance at run time without a dictionary passing scheme,
    as in Rust's object safety rule.
  - **Error:** E0460 stays for this case, with its message narrowed to "an interface method cannot be generic".
  - **Allowed:** a class may implement an interface *and* have additional generic methods.
- **Static methods** may be generic, but their signature still must not mention the class's type parameters
  (unchanged, ADR-0026).
- **Contracts** on a generic method are checked per instance at run time. The verifier treats a type parameter
  abstractly, as for generic functions (ADR-0036).

### 2. `void` as a type argument

```ts
function run<T>(f: () => T): T { return f(); }
run(() => { console.log("hi"); });  // T = void
const h = s.spawn(() => log(x));    // TaskHandle<void>; h.join(): void
```

- **Inference:** a closure or function whose result type is `void` instantiates `T = void`; explicit `<void>` is
  allowed too.
- **Semantics:** `void` as a type argument is the unit type. It has exactly one value and no runtime representation.
  - Inside the instance, a value of type `T = void` is never materialised:
    - a local of that type is dropped;
    - a field of that type takes no space;
    - `return f()` is `f(); return`.
  - `Option<void>`, `Result<void, E>` and `T[]` with `T = void` are allowed. `T[]` with `T = void` keeps only its
    length, and its elements carry no data.
- **Lowering:** happens per instance after substitution. The rule "a void value has no slot" is applied in
  `lower/` and is checked by the MIR verifier: no local, field or operand has type void.
- **Not changed:**
  - writing `void` as a value is still an error;
  - `void` as a parameter type is still an error;
  - functions written with `: void` keep their meaning.

### 3. Follow-up in the std (part of this change)

The twin APIs become one API each, and the old names stay one release as deprecated wrappers (`@Deprecated`,
ADR-0024):

| Today | After |
|---|---|
| `scope` / `scopeDo`, `spawn` / `spawnDo` (free functions) | `scope(s => ...)` with `s.spawn(f)`; the result is `TaskHandle<T>` including `T = void` |
| `Graph<T>` free helper functions forced by E0460 | methods where that reads better |

Other std helpers forced by E0460 are listed by the implementing worker and converted in the same PR, when the
conversion is mechanical.

## Proof obligations and assurance

- **Monomorphisation preserves meaning:** a generic method instance is an ordinary MIR function. The ownership
  verifier and the Lean model need no change; the differential tests cover it.
- **The unit erasure for `void` is covered by:**
  - a verifier rule (no void slot);
  - differential tests C vs LLVM and opt vs `--no-opt`;
  - conformance tests for `T = void` in functions, methods, `Option`, `Result`, arrays and closures.
- **Error tests:**
  - an interface generic method gives E0460;
  - `void` as a value or a parameter type keeps its errors;
  - inference failures keep E0407 with the old text.

## Not in scope

**Closures that capture a resource handle stay rejected** (E0450–E0452), because a captured handle could outlive
its scope. Examples are `useListenerNet` and `useConnectionBeside` in `std:net`, and `scopeFs` in `std:task`.

The right fix is a *scoped* closure that **borrows** the handle for the duration of the call and cannot escape. That
is the same machinery as the borrow inference of ADR-0038 §2, so it is designed together with it, in a separate
ADR.

## Order

- **When:** implemented after the current rewrite wave (3b and 3c) and the concurrency PR. It touches `check/`
  (instances, inference, classes), `lower/` (void slots) and `verify/` (the void rule).
- **Gate:** bootstrap fixed point and byte-identical output for every existing program, because the extension must
  not change any existing instance.
