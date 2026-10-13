# ADR-0001: Stage 0 in Rust, emitting GNU C

Status: accepted (2026-10-13)

Spec 09 allows a host-language Stage 0 targeting C. We use Rust (std only, no crates) for
`bootstrap/orinb`. Generated C uses GNU extensions (statement expressions `({ ... })`,
`__builtin_*_overflow`) supported by gcc and clang; this keeps both Stage 0 and the Orin-written
Stage 1 code generator small. Portable ISO C (or LLVM/Cranelift) is a later backend concern.
The spec folder was renamed `specs/` → `spec/` to match `spec/spec.md` ("Package/spec folder").
