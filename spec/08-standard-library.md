# 08 — Standard Library Design

## Design principle

Use **JavaScript/TypeScript-familiar names** and predictably typed signatures. Agents should recognize most operations without learning novel naming conventions. Unlike JS: no `undefined`, no nullable results, no implicit coercions, no throw-on-ordinary-failure, no hidden shared mutable array methods. The core/stdlib split lets high-level APIs lower to efficient primitives.

## Modules (proposed)

| Module | Representative APIs | Failure semantics |
|---|---|---|
| `std:array` | `map`, `filter`, `find`, `reduce`, `some`, `every`, `get`, `sort` | `find/get: Option<T>` |
| `std:string` | `split`, `trim`, `includes`, `replace`, `toLowerCase`, `join` | fallible variants return `Result` |
| `std:map` | `new Map<K,V>()`, `get`, `set`, `has`, `delete`, `size`, `keys`, `values`, `entries` (built in, no import; keys: any `Hash` type, ADR-0034 (integers, bool, string, and records, unions, `Option`, arrays and classes with `hash` built from them); insertion order; value semantics; Orin prelude `library/collections/map.or`, ADR-0018) | `get: Option<V>` |
| `std:json` | `parse<T>`, `stringify` | `Result<_, JsonError>` where fallible |
| `std:fs` | `readFile`, `writeFile`, `exists` | `Result<_, FileError>` |
| `std:path` | `join`, `basename`, `extension` | typed, platform-aware |
| `std:http` | `get`, `post`, `serve` | `Result<_, HttpError>` |
| `std:time` | `now`, `sleep`, `duration` | explicit units |
| `std:math` | `min`, `max`, `abs`, `sqrt`, `pow`, `floor`, `ceil`, `round`, `PI`, `E` (float only; `library/collections/math.or`, ADR-0018) | IEEE edge cases defined in the file header |
| `std:task` | `spawn`, `all`, `parallelMap` | isolated tasks/errors |
| `std:system` | safe native buffers, handles, atomics | isolated trusted implementation |

Example:

```typescript
import { readFile, FsGrant } from "std:fs";
import { parse } from "std:json";
function loadUsers(fs: FsGrant, path: string): Result<User[], AppError> {
  const text = readFile(fs, path)?;
  return parse<User[]>(text);
}
```

Array transformations are pure/logical-value operations; methods like JS `push` that mutate shared state are not offered unchanged. `sort()` produces a new logical value. A locally mutable collection MAY have specially named APIs later, but not ambiguous mutation conventions.

## Runtime and performance

`std` is the ergonomic layer; `core` holds minimal trusted primitives, layouts and intrinsics. Optimizer SHOULD fuse compatible array pipelines, eliminate temporaries, and specialize static calls when semantics permit. Familiarity must not introduce full JS object/prototype semantics.

Async/network concurrency is **OPEN**: a synchronous `http.get` can be useful but cannot be the only scalable programming model. Design async/await or tasks without new error and ownership paradigms. `std` APIs must have precise allocation, complexity, resource and failure contracts for MCP symbol inspection.

## Validation

Every public API entry needs (a) signature, (b) errors/absence, (c) behavior, (d) complexity/allocation notes, (e) minimal example. Generate structured machine-readable symbol data from compiler source to prevent documentation/signature drift. Benchmark code generation with agents unfamiliar with Orin but familiar with TS/JS.
