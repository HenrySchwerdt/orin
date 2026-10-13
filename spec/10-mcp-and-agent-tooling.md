# 10 — Compiler-Integrated MCP and Agent Tooling

## Goals

`orin mcp` SHOULD ship with the compiler. Agents can query signatures, get concise incremental diagnostics, apply compiler-safe edits, run targeted tests, and trigger builds without reading massive compiler outputs. The same compiler service layer powers LSP and MCP.

## Small initial tool surface

| Tool | Operation |
|---|---|
| `check` | Project/changed-file validation; snapshots or delta diagnostics |
| `inspect` | Symbol/module signature, dependencies, generated annotations, memory report |
| `edit` | Validated refactors (rename, apply deterministic fix), subject to permission |
| `test` | Targeted or module tests, structured summary |
| `build` | Native build, artifacts, diagnostics |

Tool requests/responses use the protocol's schema and the actual pinned MCP spec. The following are *illustrative payloads*, not claimed current wire-level specification:

```json
{"scope":"changed","format":"compact","sinceRevision":41}
```

```json
{"revision":42,"resolved":["E104"],"added":["E201"],"remaining":1}
```

Use content-stable diagnostic identities plus project revision IDs. Delta output is allowed only if the client has the matching base revision; otherwise return a full snapshot. Offer `compact` and `detailed` modes. Minimize total *agent* token usage, not only one tool response.

## Introspection

`inspect("Array.find")` should provide signature (`Option<T>`), purity, complexity, allocation characteristics and a minimal example. `inspect(module)` should return exports and dependency graph. `inspect(annotation)` should summarize generated handlers/validators and runtime costs. `orin memory --report` exposes allocation categories, RC operations, uniqueness checks and confirmed optimization outcomes, never invented zero-allocation claims.

## Security

MCP access is not inherently privileged. Constrain workspace read/write to authorized roots. Refactoring changes require authorized write access. Test/build commands can execute untrusted project code and must run under explicit permissions/sandbox policy. Never allow annotation plugins or MCP clients to bypass safe-code/FFI boundaries.

## Token-efficiency benchmarks

Measure full tokens through task completion: prompts + code + MCP/tool responses + retries/repairs; additionally measure test pass rates, latency, human reviewability, and compilation repairs. A shorter diagnostic that forces several follow-up calls is not automatically better.

MCP compatibility must be checked against the official protocol version chosen for implementation. See `13-research-references.md`.
