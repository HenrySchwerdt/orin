# ADR-0002: Uniform boxed, reference-counted object model for bootstrap

Status: accepted (2026-10-13)

All non-scalar values are pointers to RC'd heap objects with 64-bit slots (see
docs/architecture.md). Generic types (`T[]`, `Option<T>`, `Result<T,E>`) therefore need no
monomorphization: a slot holds either a scalar or a reference, recorded per object
(array flag / struct bitmask). Mutation is copy-on-write on count==1 (spec 06 "uniqueness
tests and allocation reuse"). This is the "conservative RC scheme" spec 06 says to start with;
unboxing, retain/release elision, regions and the OIM verifier come later and must preserve
the same observable semantics.
