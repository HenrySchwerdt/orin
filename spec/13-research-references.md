# 13 — Research and Engineering References

These sources motivate parts of Orin, but **do not prove Orin itself safe or performant**. The formal claims in `07-formal-safety.md` remain research/engineering deliverables.

1. **Reinking, Xie, de Moura, Leijen (2021)** — *Perceus: Garbage Free Reference Counting with Reuse*. PLDI. Precise optimized reference counting and reuse, formal justification and practical Koka implementation. https://doi.org/10.1145/3453483.3454032
2. **Tofte & Talpin (1997)** — *Region-Based Memory Management*. Region inference and lifetime analysis. https://doi.org/10.1006/inco.1996.2613
3. **Koka Language** — Documentation, effect types and memory management work. https://koka-lang.github.io/koka/doc/book.html
4. **Lean 4 Reference Counting** — Practical compiler-managed RC and reuse. https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/
5. **Swift Ownership Manifesto** — Value semantics, copy-on-write, optimization and ownership tradeoffs. https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md
6. **RustBelt** — Semantic foundations for Rust safety abstraction and unsafe implementations. https://plv.mpi-sws.org/rustbelt/
7. **CompCert** — Verified optimizing compilation and importance of backend preservation. https://compcert.org/
8. **Model Context Protocol** — Official specification, tools/resources and versioning. https://modelcontextprotocol.io/specification
9. **The Rust Reference / Procedural Macros** — Relevant compiler-time expansion precedent (not a direct mandate to use Rust macros). https://doc.rust-lang.org/reference/procedural-macros.html
10. **Lean or Rocq proof assistants** — Potential proof mechanization. https://lean-lang.org/ ; https://rocq-prover.org/

## Evidence categories

- **Established:** RC, reuse analysis, region inference, typed core safety theorems and verified compiler techniques have research precedents.
- **Not established for Orin:** combining TypeScript-like mutable class surface syntax, implicit value-copy semantics, OIM optimizations, annotations, concurrency and native codegen while retaining all safety properties and achieving benchmark targets.
- **Future validation:** formalize and prove the Orin-specific theorems, implement and benchmark independently, report negative outcomes.
