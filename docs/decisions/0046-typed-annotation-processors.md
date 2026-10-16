# ADR-0046: Typed user-defined annotations and deterministic compile-time processors

Date: 2026-10-16. Status: proposed (design only; no implementation).
Related: spec/05-annotations-and-metaprogramming.md, ADR-0012 (contracts), ADR-0016 (1.0 scope), ADR-0024 (built-ins), ADR-0044 (OX), ADR-0020/0023 (OSIG).

## Context and goal

Today `compiler/syntax/ast.or` represents only `ATest | ADeprecated | AInline | ASealed`; `compiler/syntax/parser.or` rejects other annotation names with E0408. `compiler/check/annotations.or` handles compiler-defined annotations. Contracts (`@Requires`, `@Ensures`, `@Invariant`, `@Decreases`, `@Rule`) are **not annotations** and remain reserved. Spec 05 anticipates custom processors but leaves the definition syntax, hygiene, execution and packaging unresolved.

Provide library-defined, typed compile-time metadata and separately opt-in processors to generate static routes, serializers, validation and dependency graphs. No runtime reflection, proxy factories or dynamic classpath scanning; no compiler knowledge of framework-specific annotation names. This ADR proposes an additive **post-1.0** feature unless ADR-0016 is explicitly amended. It does not claim implementation or change the 1.0 freeze.

## Decision: three separate capabilities

1. **Definitions and uses.** Libraries declare an annotation name, constant parameter types, legal declaration targets and compile-only retention. Imported annotation names resolve through the ordinary module visibility rules. Only pure compile-time constants (primitives, enums/tagged values or bounded immutable literal aggregates as explicitly supported) are admissible; no arbitrary user expressions, effects or user constructors during argument evaluation. Duplicate use, target mismatch, bad arguments and unknown names produce stable diagnostics. Built-ins retain existing semantics and syntax.
2. **Read-only semantic queries.** Processor code receives immutable, snapshot-based symbol/type views: public names, declared member signatures, applied annotation arguments and *read-only* contract information. Queries cannot mutate AST/HIR, bypass private module boundaries, or receive capabilities to execute I/O.
3. **Additive generation.** Processors emit *new* typed declaration/module builder nodes via a constrained interface, together with diagnostics and source-origin mappings. No arbitrary text injection, raw LLVM/MIR, replacement of existing bodies, deletion of contracts, changes to original declarations or direct mutation of imported modules. Generated code is re-resolved, fully type/module/effect checked, lowered and independently MIR ownership-verified. Generated definitions inherit ordinary visibility/architecture restrictions; processor authority never exceeds that of the compiling package.

### Illustrative surface (not accepted language grammar)

```orin
// Proposed only; syntax deliberately non-binding.
@Annotation({ targets: [Target.Class], retention: "compile" })
export class Controller {
  constructor(public path: string) {}
}

@Controller("/users")
export class UserController { /* ... */ }
```

The API shape below is conceptual, **not** currently supported (generic interfaces are not yet supported). Prefer a generic registration function with a non-generic processor protocol in the initial implementation, or explicitly add the required language capability in its own ADR.

```orin
registerProcessor<Controller>(controllerProcessor);
```

Do not rely on decorators executing at runtime or user-defined `@Controller` being a compiler keyword.

## Pipeline and ordering

1. Parse built-ins/contracts unchanged and preserve unresolved custom annotation syntax in AST (name, positional/named argument expression syntax, span, target, origin).
2. Resolve imports and initial declarations/signatures, and type-check annotations and their compile-time constant arguments. Materialize a *read-only semantic snapshot* with stable symbol identities.
3. Discover **explicitly declared** processor dependencies from a package manifest (illustrative `[annotations] processors = ["pkg/processor"]`); resolve versions, lockfile and dependency DAG. Never scan the filesystem or load arbitrary modules implicitly.
4. Run processors in a deterministic order (dependency order, then stable module/source/processor ordering). Expand in bounded rounds with cycle detection and a global generated-declaration budget; a newly generated annotation is inert unless a future explicit rule enables another round.
5. Validate generated trees, hygienic names, visibility, source mappings and provenance; merge into a virtual generated module namespace; re-resolve and recheck the **complete affected program** before standard HIR → MIR → verifier → backend. No emitted declaration is trusted because it came from a processor.

The initial MVP restricts generation to standalone functions and modules, not injected class members or alterations to user declarations. Interfaces for further node kinds require explicit follow-up design.

## Compiler and package boundaries

- `compiler/syntax/ast.or`, `compiler/syntax/parser.or`: retain a custom annotation node alongside existing closed built-ins; preserve current contract grammar, placements and parser recovery.
- `compiler/check/annotations.or`, `compiler/analysis/`: typed resolution, constant evaluation, target validation and immutable symbol/type queries. Avoid coupling all processor execution to the checker.
- New `compiler/meta/`: protocol/versioned immutable semantic DTOs, builders, hygiene, diagnostics and origin tracking.
- New `compiler/expand/`: processor discovery, DAG, execution budgets, deterministic scheduling, virtual generated units and recheck.
- `compiler/loader/` and manifest/lockfile: opt-in processor dependencies and explicit trust policy.
- Future `stdlib/meta.or` (or a dedicated `std:meta` module) is a **compile-time** SDK only, not a runtime standard-library dependency.
- Integrate expansion before HIR lowering; generated declarations pass the existing MIR verifier for both C and LLVM backends.
- OSIG must retain `generated_by` edges from output symbol → processor version → originating annotation and source span; mark processor-origin/effects in diff/report output.

## Execution model and safety

**Do not execute arbitrary native plugins inside the compiler process.** The long-term default is a restricted Orin compile-time evaluator/VM with no ambient host access and no FS/network/process/clock/random capabilities. Its instruction/fuel, recursion, heap, emitted-node, expansion-depth and wall-clock supervisory limits are explicit and configurable within hard maxima. Termination by fuel is mandatory; a time limit alone is insufficient for reproducibility. Inputs are only declared source/config/toolchain/dependency artifacts. Outputs are only generated declarations and diagnostics. Cache keys cover processor binary/version, SDK/ABI, compiler version, input symbol snapshot, manifest and arguments. No caching if determinism cannot be established.

A staged MVP **may first support declarative metadata and bounded compiler-implemented transforms**, without shipping a VM or falsely presenting native processor execution as sandboxed. Processor trust/execution policies must be documented and reviewable; untrusted processors require an isolation mechanism before general distribution.

### Contracts, permissions and hygiene

- Reserved contract clauses cannot be shadowed, emitted, deleted or rewritten; processors may inspect them read-only.
- Stable hygienic generated symbol IDs prevent accidental capture/collision. Public generated names require explicit declaration and conflict checks.
- Processor metadata access is scoped by ordinary module visibility. No private symbol leaks, forged grants, unverified native FFI, arbitrary raw pointers or bypass of resource/effect restrictions.
- If a processor generates or refers to privileged I/O, standard capability requirements and effect-policy gates still apply to the final program.
- All failures have deterministic diagnostic codes, source ranges, expansion traces and bounded error recovery; no silent fallback to partially expanded output.
- Versioned SDK, serialized IR schema and ABI are required for external processors; incompatible versions must be rejected.

## Alternatives

- **Mutable AST plugins:** rejected; makes contracts, source provenance, type checking and ownership verification difficult to reason about.
- **Raw generated source strings:** rejected as the primary API; poor hygiene and unstable diagnostics. A later convenience layer may lower to the same validated builders.
- **Arbitrary native dynamic libraries:** rejected as the default; violates the trust boundary and deterministic sandboxing.
- **Runtime reflection/proxies:** rejected; incompatible with zero-reflection native framework generation goals.

## Delivery slices and merge gates

1. **PR A — syntax and typed metadata definitions.** Parser/AST/resolution, legal targets, constant arguments, import visibility, duplicate semantics, diagnostics. No execution. Existing built-ins and contracts unchanged. Parsing/recovery/error tests and byte-identical output for unaffected programs.
2. **PR B — read-only metadata SDK.** Stable symbol/contract views, cross-module permissions, deterministic snapshots, SDK version. Tests for privacy, type identity, generic substitutions and consistent diagnostics; no codegen yet.
3. **PR C — declaration builder and expansion pipeline.** Additive standalone function/module generation, origin mappings, name hygiene, re-resolution, rechecking, module cycle prevention, both backends and ownership verification. Negative tests for malformed or privilege-escalating output.
4. **PR D — restricted Orin processor evaluator.** Execute processor programs with fuel/memory/emission budgets, deterministic order, no ambient I/O, compatibility and cache tests. Validate failures, infinite loops, recursive emission and malicious processors.
5. **PR E — framework proof of usefulness.** Two independent packages (e.g. `@Controller/@Get` static route table and `@Json` typed codec) without compiler-specific keywords. Golden generated-declaration snapshots, diagnostics, OSIG provenance and C/LLVM differential testing.

No slice introduces behavior before it is implemented and covered by tests. Run existing bootstrap fixed-point, conformance, formatter/LSP, MIR verifier/mutation, backend differential and toolchain tests on each applicable change. Budget processor execution and regression-benchmark compile time and binary size.

## Open decisions to resolve in PR A/B

- Exact syntax for annotation declarations, named/default arguments, repeatability, inheritance and targets.
- Constant value grammar and whether user-defined record literals are allowed.
- Processor package manifest syntax, versioning and declaration ordering.
- Symbol identity stability across incremental rebuilds and generic monomorphization.
- Processor SDK compatibility and immutable typed builder API; what is exposed from private modules.
- Whether any annotations are retained in binary metadata (default: no).
- How and whether generated annotations can trigger additional rounds (default: no).
- Sandboxing and reproducibility implementation choice for PR D.

## Relationship to runtime R3 and scheduling

Annotation metadata and the first read-only SDK can proceed independently of R3 core runtime migration. They do not grant raw memory access. The compile-time evaluator needs an explicit implementation/isolation plan; it must not delay correctness of R3 or be treated as an existing runtime feature. Shipping custom processors before 1.0 requires a separate amendment to ADR-0016, not this proposal alone.
