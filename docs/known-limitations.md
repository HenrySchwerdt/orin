# Known limitations
- Orin-B only (see bootstrap-subset.md): no closures (the self-hosted compiler has them, below), floats, annotations. The
  self-hosted compiler additionally accepts simple generics (ADR-0007: no bounds, no generic
  methods, no default type arguments; instantiation depth limit 32, E0413).
- Memory safety is not formally established; see architecture.md "Safety status".
- Stage 0 stores string literals as Rust `String`: `\xHH` escapes ≥ 0x80 that are not valid UTF-8
  become U+FFFD under Stage 0 (the self-hosted compiler keeps raw bytes).
- Early exits from inside expressions (`?`, diverging match arms) may leak temporaries (safe, not
  freed). Records/variants are limited to 64 slots.
- No hash maps in Orin-B; compiler symbol tables use linear search.
- Closures (ADR-0011, self-hosted compiler only): capture by value only (no mutation of captured names,
  E0401; no recursive arrows, E0300); no `function` expressions, default/rest parameters or generic arrows;
  an arrow as a `?:` branch needs parentheses; parameter types of an arrow need an expected function type
  (or annotations, E0407); builtin functions (`parseInt`, ...) and class methods cannot be used as values;
  the legacy backend (`--legacy-codegen`) rejects programs with closures. Array methods: `indexOf` /
  `includes` only for `int`, `usize`, `bool`, `string` elements (E0405 otherwise); `sort` is O(n log n) with
  O(n) extra allocation per level; the callbacks' integer results must be `int` (`.toInt()` on lengths).
- Classes (ADR-0009, self-hosted compiler only): no inheritance (`extends`, E0408), generic classes or
  methods (E0408), static fields, getters/setters, interfaces, `protected`. Private members are
  checked at compile time (E0405). Constructors initialise fields only through leading `this.f = e;`
  statements, parameter properties and field initializers (else E0411; `this` is unavailable until
  then, E0300). Mutating methods are inferred; every mutating call copies the receiver shallowly until
  ADR-0010 lands (e.g. `this.items.push(x)` in a loop is O(n) per call). A call of a mutating method
  is hoisted before its statement, so it is rejected inside `&&`/`||` operands, `?:` branches and
  `while` conditions (E0408), runs before the other operands of the same statement, and its receiver
  may not contain side-effecting index expressions (E0408). Class values cannot be built with record
  literals outside their class (E0408). Method hover types on the call expression show the lowered type.
