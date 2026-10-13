# ADR-0007: Simple parametric generics by abstract check + monomorphization

Status: accepted (2026-10-13). Scope: the self-hosted compiler (`compiler/`). Stage 0 is frozen and
still rejects generics with E0408; the compiler's own source stays within Orin-B.

Spec 02 asks for "simple parametric generics (e.g. `function first<T>(xs: T[]): Option<T>`)",
statically resolved, with specialization/monomorphization "an implementation choice, bounded to
avoid pathological code-size growth". This ADR fixes the first slice. Constraints/bounds, generic
methods, higher-kinded types, default type arguments and generic closures stay OPEN/out of scope.

## Language accepted

* Generic functions `function f<A, B>(...)`, generic records `type Pair<A, B> = { ... };`, generic
  unions `type Tree<T> = Leaf | Node(Tree<T>, T, Tree<T>);` and generic aliases
  `type List<T> = T[];`. Type parameters are plain names; they must be distinct (E0304) and must
  not reuse a built-in type name (E0408).
* Type applications `Pair<int, string>` need exactly as many arguments as parameters (E0400); a
  non-generic type given arguments is E0400. `Option` / `Result` / arrays are unchanged.
* Calls infer type arguments (below); explicit arguments `f<int>(x)` and `Node<int>(l, v, r)` are
  allowed. Records: `Pair<int, string> { ... }` or `Pair { ... }` (inferred). A nullary generic
  variant (`Leaf`) needs an expected type.
* Syntax: `name<types>(` and `Name<types> {` are generic forms only if a well-formed type list
  followed by `>` and then `(` / `{` can be parsed at that position (backtracking); otherwise `<`
  is the comparison operator. (`f(a < b, c > (d))` is therefore a generic call, as in C#.)
  AST: `ETyApp(name, types)` (callee only) and `ERecordT(name, types, spread, fields)`; Stage 0
  never produces them.

## Checking: once, abstractly

Every generic function and type is checked once at its definition with *opaque* type parameters,
so errors are reported at the definition and independently of any call. Inside a generic body a
`T` value supports only what every type supports: binding, passing, returning, storing in
arrays/records/Option/Result, matching on containers. `==`, `+`, `<` (E0410), methods and fields
(E0405), `match` on a `T` (E0402), literals as `T` (E0400) and `T { .. }` are rejected.

The opaque type is implemented without any new HIR type: it is a field-less record named after
the parameter, appended to a *scratch* copy of the environment that is discarded after the check
(so opaque types never reach HIR or codegen; `hir.or` is unchanged). In an abstract check no
function instances are created.

## Monomorphization: re-check under a binding

Every distinct instantiation becomes a concrete HIR entity, so codegen is unchanged:

* Types: `Pair<int,string>` becomes a `RecordDef` (union: `UnionDef`) named
  `main.Pair<int,string>` (module-qualified name, argument types without spaces), created on first
  use and registered *before* its fields are resolved so recursive types terminate.
* Functions: `first<int>` becomes a `Function` named `main.first<int>`, produced by checking the
  generic body again with the type parameters bound to the concrete types (the abstract check
  guarantees this only ever fails for instantiation-limit reasons). Aliases are expanded.
* The instance table `Env.insts` (kind, generic id, argument types, id, depth) memoizes
  instances. Ids: ordinary functions first (as before), instances appended in discovery order;
  the driver checks `env.funcs` by index until it stops growing, so output is deterministic.
* Only instantiations requested from checked concrete code are emitted. Ordinary functions are all
  checked and emitted as before (even if unreachable from `main`); unused generic functions emit
  nothing.

Checker state: the environment grows while a body is checked, so `FnCtx` carries `env`
(`fx.env`) and every checking function returns it with its result. `Env.gtypes` / `Env.gfuncs`
hold the generic declarations; `TypeEnt.EntGen`, `ValEnt.VGFunc` / `VGVariant` name them in the
module scopes (import/export/re-export work unchanged; importing a generic union brings its
variants).

## Inference

For a call to a generic callee (function, variant constructor or record literal) the type
arguments are bound in this order: explicit arguments; else unification of the callee's result
type with the expected type; then the arguments left to right (parameter type expressions are
unified with argument types, structurally through arrays, `Option`, `Result`, generic types and
generic aliases). Arguments that cannot be typed alone (`[]`, `None`, `Leaf`, ...) and bare
integer literals are deferred until everything else is known; literals default to `int` last.
A parameter still unbound is E0407; conflicting bindings surface as an ordinary E0400 mismatch.
Type arguments may not be `void`.

## Bound on code-size growth: E0413

New error **E0413 "generic instantiation limit exceeded"**: the instantiation nesting depth of
functions (an instance requested while checking an instance of depth d has depth d+1; ordinary
functions have depth 0) and of types (nesting of type applications while resolving the fields of
an instance, aliases included) may not exceed 32. Polymorphic recursion (`f<T>` calling `f<T[]>`)
and infinitely expanding types (`type C<T> = { next: Option<C<T[]>>; }`) hit it.

## Alternatives considered

* A `TyParam` HIR variant plus HIR substitution: more code in the checker and codegen traps for
  something that never reaches codegen; the opaque scratch record gives the same abstract-check
  semantics for free.
* Type erasure / dictionary passing: contradicts the uniform value model's static layout needs for
  scalars (`int` vs boxed) and the monomorphic C output.

## Consequences

`tests/errors/e0408_generic_*.or` now test the remaining E0408 case (a type parameter named like a
built-in type), which Stage 0 also reports. Tests for the new language live in `tests/next/`
(`tools/run_tests.py --suite next`); Stage 0 is not expected to pass them. Known limitations: instance lookup is linear; ordinary functions unreachable from `main` still
instantiate the generics they call; no generic methods, bounds or default type arguments.
