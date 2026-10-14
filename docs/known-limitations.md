# Known limitations
- Integers (ADR-0022): `i128` / `u128` are rejected (E0431); arrays of narrow integers use 8 bytes per element; `orin verify --contracts` models every integer width exactly (ADR-0035); `sort` comparators return `int`; no bitwise operators or shifts exist in the language. Template literals: no `\u` escapes, no tagged templates; the formatter prints them verbatim.
- Orin-B only (see bootstrap-subset.md): no closures (the self-hosted compiler has them, below), floats, annotations. The
  self-hosted compiler additionally accepts simple generics (ADR-0007: no bounds, no generic
  methods, no default type arguments; instantiation depth limit 32, E0413).
- Memory safety is not formally established; see architecture.md "Safety status".
- Early exits from inside expressions (`?`, diverging match arms) may leak temporaries (safe, not
  freed). Records/variants are limited to 64 slots.
- No hash maps in Orin-B; compiler symbol tables use linear search.
- Closures (ADR-0011, self-hosted compiler only): capture by value only (no mutation of captured names,
  E0401; no recursive arrows, E0300); no `function` expressions, default/rest parameters or generic arrows;
  an arrow as a `?:` branch needs parentheses; parameter types of an arrow need an expected function type
  (or annotations, E0407); builtin functions (`parseInt`, ...) and class methods cannot be used as values;
  Array methods: `indexOf` /
  `includes` only for `int`, `usize`, `bool`, `string` elements (E0405 otherwise); `sort` is O(n log n) with
  O(n) extra allocation per level; the callbacks' integer results must be `int` (`.toInt()` on lengths).
- Classes (ADR-0009, self-hosted compiler only): no inheritance (`extends`, E0408), generic methods (E0460), static fields, getters/setters, `protected`. Private members are
  checked at compile time (E0405). Constructors initialise fields only through leading `this.f = e;`
  statements, parameter properties and field initializers (else E0411; `this` is unavailable until
  then, E0300). Mutating methods are inferred; every mutating call copies the receiver shallowly until
  ADR-0010 lands (e.g. `this.items.push(x)` in a loop is O(n) per call). A call of a mutating method
  is hoisted before its statement, so it is rejected inside `&&`/`||` operands, `?:` branches and
  `while` conditions (E0408), runs before the other operands of the same statement, and its receiver
  may not contain side-effecting index expressions (E0408). Class values cannot be built with record
  literals outside their class (E0408). Method hover types on the call expression show the lowered type.
- Generic classes (ADR-0026): no generic methods (E0460); static methods cannot use the class type parameters
  (E0461); one interface bound per parameter; instances are created on demand, so an instance method that is never
  called is only checked abstractly; a `?` in a mutating method with a result is hoisted like a mutating call.
- Interfaces (ADR-0019, self-hosted compiler only): nominal conformance (`implements`), method signatures only
  (no fields, default methods, `extends`, type parameters: E0408), non-mutating methods only (a mutating
  implementation is E0418), one bound per type parameter (`T extends A & B` is E0408). A class converts
  implicitly to the interfaces it declares (the only implicit conversion; not lifted over arrays); no
  downcasts, no `instanceof`, `==` on interface values is E0410. Interface values are boxed (one allocation
  per conversion, one indirect call per method call). Go-to-definition from a call on a bounded type parameter inside a generic body
  resolves to the interface method; hover shows the implementations of an interface.
- Built-in annotations (ADR-0024, self-hosted compiler only): only `@Test`, `@Deprecated`, `@Inline` exist;
  any other `@Name` is E0408 and user-defined annotations are post-1.0. `orin test` runs `void` tests that fail by
  trapping (no `Result` tests, fixtures, parameterised tests, parallel runs, coverage); it finds the tests of the
  modules the entry loads, builds with the C backend and needs a C compiler. `@Deprecated` warnings are not listed
  by the MCP `check` tool. `@Inline` is a hint (a recursive `@Inline` function is E0444; calls through function
  values and interface methods are not followed by that check).
- Capability grants (ADR-0027, std I/O unstable until the freeze): a grant is a resource handle, so it is a scope-function
  parameter only: a closure cannot capture one (E0452; take all grants with `useHost`, pass them as arguments, or use
  `withFileFs`), there is no `host.fs()` returning a grant, and at most 256 grants are live at once. `console.*` and
  `exit` need no grant (ambient output). Path scopes are checked lexically and through symbolic links at the time of the
  operation (no protection against races, hard links or mounts); `shell` is outside every grant; a denied
  operation that cannot return an `Err` traps; the network and environment families are reserved only.
