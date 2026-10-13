# 05 — Annotations and Compile-Time Generation

## Principle

Offer Java-like `@Annotation(...)` syntax, but make annotations **compile-time, typed, deterministic transformations**. They MUST NOT imply runtime reflection, proxy factories, classpath scans or a JVM-like VM.

```typescript
@Controller("/users")
export class UserController {
  constructor(private users: UserService) {}

  @Get("/:id")
  getUser(id: int): Result<User, HttpError> {
    return this.users.find(id);
  }
}
```

Potential generated artifacts: static route table, typed decoders/encoders, validation code, dependency graph, documentation metadata and MCP summaries. Runtime HTTP parsing and validation still cost time; *avoiding dynamic framework overhead* does not make those operations free.

## Annotation categories

1. **Compiler built-ins**: `@Test`, `@Deprecated("message")`, `@Inline` — finalized and implemented for 1.0 core
   (ADR-0024, docs/testing.md); `@Repr` is not part of 1.0 core. These are a closed, compiler-defined set with
   their own grammar and AST node; they are the *only* annotations in 1.0 core (any other `@Name` is E0408) and
   are not an extension point. Contract clauses (`@Requires`, ...) are separate constructs (ADR-0012).
2. **Typed code generators**: `@Json`, `@Controller`, `@Get`, `@Service`, `@Validate`.
3. **Metadata**: `@Description`, `@Permission`, `@Example`.

Custom annotation implementations MAY be introduced after self-hosting. They MUST generate typed AST or a restricted IR, not raw machine code or arbitrary unchecked LLVM IR. Generated output is re-resolved, type-checked, module-checked and run through OIM memory verification.

## Safety and termination

- Compilation MUST be deterministic for identical sources/configuration/tool versions.
- Compile-time transformations MUST be sandboxed or from a restricted terminating language; enforce finite recursion, time/memory quotas and expansion limits.
- No unrestricted network, filesystem write or host execution during compilation.
- No bypass of private module symbols, ownership checks, type checks or FFI trust rules.
- Generated symbol origins and source maps SHOULD remain reviewable.

## Dependency injection

Services use static dependency graph construction. Cycles, missing dependencies and illegal module imports are compile errors. No required empty `@Module` class: `module.or` already defines the boundary. Singleton/lifecycle/resource semantics MUST be defined separately; connection handles cannot be silently copied as ordinary values.

## Compile-time sequence

Parse -> name resolution -> annotation collection -> bounded expansion -> re-resolution + type check -> lower classes -> core IR -> memory analysis -> codegen. Recursive expansion must terminate under a clear finite budget.

## OPEN

Exact annotation-definition syntax, metadata retention policies, hygienic symbol generation, plugin distribution/permissions, evaluation order and interaction with generic specialization remain unresolved. `@Get`, `@Service`, etc. are framework conventions built atop the annotation mechanism, NOT all mandatory compiler keywords.

## Contract clauses are not annotations (2026-10-13)

`@Requires`, `@Ensures`, `@Invariant`, `@Decreases` and `@Rule` share the `@` spelling but are
**core-language contract clauses** (spec 15 §4.2a, ADR-0012), not annotations. Their names are
reserved; annotation definitions, imports and expansions cannot declare, shadow, generate, remove
or rewrite them. Annotation processors MAY read them through a read-only API.
