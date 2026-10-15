# 04 — Mandatory Modules and Packages

## Structure

Each `.or` file is a compilation unit. A **module** is an explicit boundary represented by a directory with `module.or` as its public entrypoint. A package may contain many modules.

```text
shop/
  orin.toml
  src/
    main.or
    users/
      module.or
      user.or
      service.or
      repository.or
    payments/
      module.or
      service.or
```

`users/module.or`:

```typescript
export { User } from "./user";
export { findUser, createUser } from "./service";
```

Outside modules, import only from the module API:

```typescript
import { findUser } from "./users";
```

Importing `./users/repository` from outside `users` MUST fail even if that path exists. Internal declarations and files are private by default. Export lists and explicit dependencies allow a reviewer and agent to understand module contracts without scanning all implementation files.

## Dependency graph

Production module dependencies MUST form a DAG. Cycles are compile errors. The compiler checks visibility and the dependency graph, independently type-checks modules against exported type signatures, and computes impacted modules for incremental builds and AI feedback. Tests may have carefully documented separate dependency scopes, but may not bypass safety.

**No mandated architectural layers:** Do not require Controller/Service/Repository/DTO for simple modules. Modules enforce API boundaries and dependencies; teams decide their internal organization.

## Package configuration (proposal)

```toml
[package]
name = "shop"
version = "0.1.0"

[architecture]
acyclic_modules = true
private_by_default = true
explicit_public_api = true

[modules.users]
allowed_dependencies = ["database", "logging"]
```

The package manifest name `orin.toml` and keys are proposed stable defaults; exact package resolution, registry format, dependency versioning, package imports and reproducibility policy remain OPEN.

**Implemented (ADR-0016):** `entry` (default `src/main.or`), `[architecture]` flags (always enforced; `false` is rejected), `[modules.<path>] allowed_dependencies`. A module is identified by its directory (containing `module.or`) relative to the entry file's directory; `.` names the root module. A module with a rule may import only the listed modules (E0501) and its own descendants; unknown module names are E0502; manifest errors are E0500 (syntax) and E0503 (invalid). The manifest is found from a package directory argument or from any file inside the package. The project CLI now supports path and Git dependencies with inline-table declarations, public imports by dependency alias, and a root `orin.lock` including transitive Git commits. Library entry is `src/module.or`; dev dependencies are available under `tests/`. Registry lookup, version ranges, and publishing remain unimplemented. See [the CLI guide](../docs/cli.md).

## Review/agent friendliness

Implemented: `orin check --deps [--format=json]` (module dependency summary), `orin api [--check <snapshot>]` (public API snapshot; exit 1 when it differs), MCP `inspect` on a module (allowed dependencies).

The compiler SHOULD emit public API snapshots and module dependency summaries in a compact form. MCP SHOULD offer change-impact and illegal-dependency explanations. Public API changes MUST be detectable by `orin check`, and optional semver-compatible API checking is a later feature.
