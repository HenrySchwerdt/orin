# ADR-0004: Tagged unions in Orin-B

Status: accepted (2026-10-13)

Spec 02 writes `type Option<T> = Some(T) | None;`; `enum` syntax is OPEN (spec 01). Orin-B uses
only the `type` form: a type declaration whose right side contains `|` or a `Name(...)` member
declares a tagged union whose members are variants with positional payloads. Variant names are
unqualified module-level constructors (as `Some`/`Ok` are) and must be unique per module;
importing a union type imports its variants. Untagged unions of existing types ("finite
unions") are not in Orin-B. `match` patterns: variant with binding/`_` sub-patterns, `_`, and
literals.
